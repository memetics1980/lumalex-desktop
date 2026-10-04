import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../platform/reader_platform_policy.dart';
import 'dictionary_engine.dart';

const _maximumResourceBytes = 20 * 1024 * 1024;

enum DictionaryContentServerRecovery { healthy, restarted }

int get _resourceCacheByteLimit =>
    ReaderPlatformPolicy.current.resourceCacheByteLimit;

int get _singleCachedResourceByteLimit =>
    ReaderPlatformPolicy.current.singleCachedResourceByteLimit;

/// Serves imported dictionary content from an isolated loopback origin.
///
/// A normal HTTP origin gives third-party dictionary packages the browser
/// environment they were authored for: relative resources, dynamic scripts,
/// media elements and local storage all behave consistently. The listener is
/// bound only to 127.0.0.1 and every session uses an unguessable token.
final class DictionaryContentServer {
  DictionaryContentServer._();

  static final DictionaryContentServer instance = DictionaryContentServer._();

  final Map<String, _DictionaryContent> _contents = {};
  final LinkedHashMap<String, DictionaryResourceData> _resourceCache =
      LinkedHashMap();
  int _cachedResourceBytes = 0;
  HttpServer? _server;
  Future<HttpServer>? _serverFuture;
  Future<DictionaryContentServerRecovery>? _foregroundRecovery;

  int get cachedResourceBytes => _cachedResourceBytes;

  int get cachedResourceCount => _resourceCache.length;

  /// Starts the loopback origin before the first dictionary document needs it.
  ///
  /// Binding the listener is small, but doing it in parallel with Chromium's
  /// first navigation makes the cold lookup path needlessly longer. The
  /// listener remains lazy for callers that never open the reader; the app
  /// explicitly invokes this method during its post-frame warmup.
  Future<void> prewarm() async {
    await _ensureServer();
  }

  /// Releases decoded resource bytes when the operating system reports memory
  /// pressure. Live WebViews can request those local resources again later.
  void releaseCachedResources() {
    _resourceCache.clear();
    _cachedResourceBytes = 0;
  }

  /// Verifies that WebKit can still reach the loopback origin after iOS has
  /// suspended and resumed the application.
  ///
  /// iOS may reclaim a listening socket while keeping the Dart objects that
  /// describe it alive. A request through the real loopback path detects that
  /// stale state. Readers create fresh sessions immediately afterwards, so a
  /// restarted listener may safely choose a new ephemeral port.
  Future<DictionaryContentServerRecovery> recoverAfterForeground() {
    final recovery = _foregroundRecovery;
    if (recovery != null) return recovery;

    late final Future<DictionaryContentServerRecovery> nextRecovery;
    nextRecovery = _verifyOrRestartServer().whenComplete(() {
      if (identical(_foregroundRecovery, nextRecovery)) {
        _foregroundRecovery = null;
      }
    });
    _foregroundRecovery = nextRecovery;
    return nextRecovery;
  }

  Future<DictionaryContentSession> openSession({
    required DictionaryEngine engine,
    required String mdxPath,
  }) async {
    final server = await _ensureServer();
    final token = _createToken();
    _contents[token] = _DictionaryContent(engine: engine, mdxPath: mdxPath);
    return DictionaryContentSession._(
      owner: this,
      token: token,
      port: server.port,
    );
  }

  Future<HttpServer> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(server);
    final starting = _serverFuture;
    if (starting != null) return starting;

    late final Future<HttpServer> nextServer;
    nextServer = _start().whenComplete(() {
      if (identical(_serverFuture, nextServer)) {
        _serverFuture = null;
      }
    });
    _serverFuture = nextServer;
    return nextServer;
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error, StackTrace stackTrace) {
        _forgetServer(server);
      },
      onDone: () => _forgetServer(server),
      cancelOnError: false,
    );
    return server;
  }

  void _forgetServer(HttpServer server) {
    if (identical(_server, server)) {
      _server = null;
    }
  }

  Future<DictionaryContentServerRecovery> _verifyOrRestartServer() async {
    final previousServer = _server;
    final server = await _ensureServer();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    var healthy = false;
    try {
      final request = await client
          .getUrl(
            Uri.parse(
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}'
              '/__lumalex_health',
            ),
          )
          .timeout(const Duration(seconds: 2));
      final response =
          await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>().timeout(const Duration(seconds: 2));
      healthy = response.statusCode == HttpStatus.noContent;
    } catch (_) {
      healthy = false;
    } finally {
      client.close(force: true);
    }
    if (healthy) {
      return previousServer == null
          ? DictionaryContentServerRecovery.restarted
          : DictionaryContentServerRecovery.healthy;
    }

    _forgetServer(server);
    try {
      await server.close(force: true).timeout(const Duration(seconds: 1));
    } catch (_) {
      // The old listener is already unusable. A new loopback listener is the
      // useful recovery path even if closing the stale handle reports an error.
    }
    await _ensureServer();
    return DictionaryContentServerRecovery.restarted;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    try {
      if (request.uri.path == '/__lumalex_health') {
        await _finish(response, HttpStatus.noContent);
        return;
      }
      final route = _resolveRoute(request);
      if (route == null) {
        await _finish(response, HttpStatus.notFound);
        return;
      }
      final content = _contents[route.token];
      if (content == null) {
        await _finish(response, HttpStatus.gone);
        return;
      }
      if (route.isDocument) {
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        final document = content.document;
        if (document == null) {
          await _finish(response, HttpStatus.serviceUnavailable);
          return;
        }
        response.headers.contentType = ContentType.html;
        if (request.method != 'HEAD') {
          response.add(utf8.encode(document));
        }
        await response.close();
        return;
      }

      // Every reader session has a new random path, so WebKit cannot reuse a
      // previously cached resource across lookups. Keep only the bounded Dart
      // LRU instead of accumulating one-off responses in iOS WebKit.
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final cacheKey = '${content.mdxPath}\u{0}${route.resourcePath}';
      final resource = _takeCachedResource(cacheKey) ??
          await content.engine.readResource(
            route.resourcePath,
            maxBytes: _maximumResourceBytes,
            mdxPath: content.mdxPath,
          );
      if (resource == null) {
        await _finish(response, HttpStatus.notFound);
        return;
      }
      _cacheResource(cacheKey, resource);
      final mimeType = resource.mimeType.replaceAll(RegExp(r'[\r\n]'), '');
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      );
      response.contentLength = resource.bytes.length;
      if (request.method != 'HEAD') {
        response.add(resource.bytes);
      }
      await response.close();
    } catch (_) {
      try {
        await _finish(response, HttpStatus.internalServerError);
      } catch (_) {
        await response.close();
      }
    }
  }

  DictionaryResourceData? _takeCachedResource(String key) {
    final resource = _resourceCache.remove(key);
    if (resource != null) {
      _resourceCache[key] = resource;
    }
    return resource;
  }

  void _cacheResource(String key, DictionaryResourceData resource) {
    if (_resourceCache.containsKey(key) ||
        resource.bytes.length > _singleCachedResourceByteLimit) {
      return;
    }
    _resourceCache[key] = resource;
    _cachedResourceBytes += resource.bytes.length;
    while (_cachedResourceBytes > _resourceCacheByteLimit &&
        _resourceCache.isNotEmpty) {
      final oldestKey = _resourceCache.keys.first;
      final removed = _resourceCache.remove(oldestKey);
      _cachedResourceBytes -= removed?.bytes.length ?? 0;
    }
  }

  _ContentRoute? _resolveRoute(HttpRequest request) {
    final segments = request.uri.pathSegments;
    if (segments.length >= 3 && segments.first == 'dictionary') {
      final token = segments[1];
      if (segments[2] == 'article') {
        return _ContentRoute.document(token);
      }
      if (segments[2] == 'resource' && segments.length > 3) {
        return _ContentRoute.resource(token, segments.sublist(3).join('/'));
      }
    }

    // Root-relative URLs inside publisher CSS/JavaScript do not use <base>.
    // Resolve those against the referring dictionary without exposing another
    // dictionary session.
    final referer = request.headers.value(HttpHeaders.refererHeader);
    final refererUri = referer == null ? null : Uri.tryParse(referer);
    final refererSegments = refererUri?.pathSegments ?? const <String>[];
    if (refererSegments.length >= 2 &&
        refererSegments.first == 'dictionary' &&
        _contents.containsKey(refererSegments[1])) {
      final path = segments.join('/');
      if (path.isNotEmpty) {
        return _ContentRoute.resource(refererSegments[1], path);
      }
    }
    return null;
  }

  void _setDocument(String token, String document) {
    final content = _contents[token];
    if (content != null) {
      content.document = document;
    }
  }

  void _closeSession(String token) => _contents.remove(token);

  String _createToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _finish(HttpResponse response, int statusCode) async {
    response.statusCode = statusCode;
    response.contentLength = 0;
    await response.close();
  }
}

final class DictionaryContentSession {
  DictionaryContentSession._({
    required DictionaryContentServer owner,
    required this.token,
    required this.port,
  }) : _owner = owner;

  final DictionaryContentServer _owner;
  final String token;
  final int port;
  bool _isClosed = false;

  Uri get articleUri => Uri.parse(
        'http://127.0.0.1:$port/dictionary/$token/article',
      );

  Uri get resourceBaseUri => Uri.parse(
        'http://127.0.0.1:$port/dictionary/$token/resource/',
      );

  bool owns(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == InternetAddress.loopbackIPv4.address &&
      uri.port == port &&
      uri.pathSegments.length >= 2 &&
      uri.pathSegments[0] == 'dictionary' &&
      uri.pathSegments[1] == token;

  void setDocument(String document) {
    if (!_isClosed) {
      _owner._setDocument(token, document);
    }
  }

  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _owner._closeSession(token);
  }
}

final class _DictionaryContent {
  _DictionaryContent({required this.engine, required this.mdxPath});

  final DictionaryEngine engine;
  final String mdxPath;
  String? document;
}

final class _ContentRoute {
  const _ContentRoute.document(this.token)
      : isDocument = true,
        resourcePath = '';

  const _ContentRoute.resource(this.token, this.resourcePath)
      : isDocument = false;

  final String token;
  final bool isDocument;
  final String resourcePath;
}
