import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/dictionary_library_entry.dart';

class AndroidDictionarySelection {
  const AndroidDictionarySelection({
    required this.accessPath,
    required this.dictionaries,
  });

  final String accessPath;
  final List<AndroidDictionarySource> dictionaries;
}

class IosDictionarySelection {
  const IosDictionarySelection({
    required this.path,
    required this.wasCopiedIntoDictionaryHome,
  });

  final String path;
  final bool wasCopiedIntoDictionaryHome;
}

class AndroidDictionarySource {
  const AndroidDictionarySource({
    required this.mdxPath,
    required this.relativePath,
    required this.sourceVersion,
    required this.mddPaths,
    required this.sidecarResources,
  });

  final String mdxPath;
  final String relativePath;
  final String? sourceVersion;
  final List<String> mddPaths;
  final List<DictionarySidecarResource> sidecarResources;
}

class _AndroidResolvedSource {
  const _AndroidResolvedSource({
    required this.mdxPath,
  });

  final String mdxPath;
}

class _CachedContentFingerprint {
  const _CachedContentFingerprint({
    required this.sourceVersion,
    required this.value,
  });

  final String sourceVersion;
  final Future<String> value;
}

/// Restores the operating-system grant and exposes Android dictionaries through
/// stable process-local paths. Android keeps a private MDX performance copy;
/// large MDD media volumes remain lazy and use their original documents.
class DictionaryFileAccess {
  static const _channel = MethodChannel('local_dictionary/file_access');

  // The UI and Rust engine intentionally own different service instances.
  // Source registration is therefore process-wide, while the persisted URI
  // list remains in DictionaryLibrary.
  static final Map<String, List<String>> _androidMddPaths = {};
  static final Map<String, List<DictionarySidecarResource>> _androidSidecars =
      {};
  static final Map<String, String> _androidAccessPaths = {};
  // Resolving an MDX must stay lightweight: on some physical Android
  // providers an MDD can be a multi-gigabyte sequential stream that has to be
  // staged before Rust can seek it. Keep the MDX and its render resources as
  // two separate preparation steps so importing a dictionary does not copy
  // media that has not been requested yet.
  static final Map<String, Future<_AndroidResolvedSource>> _androidSources = {};
  static final Map<String, Future<_AndroidResolvedSource>>
      _androidResourceSources = {};
  static final Map<String, Future<List<AndroidDictionarySource>>>
      _androidFolderScans = {};
  static final Map<String, _CachedContentFingerprint> _contentFingerprints = {};

  /// Uses Android's folder picker so one durable system grant covers each MDX
  /// and its adjacent MDD volumes. Folder discovery returns only document URIs;
  /// the private MDX performance copy is prepared later during import.
  Future<AndroidDictionarySelection?> pickAndroidDictionaryFolder() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final raw = await _channel.invokeMethod<Object>('pickDictionaryFolder');
    if (raw == null) {
      return null;
    }
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException(
          'Android returned an invalid dictionary selection.');
    }
    final accessPath = raw['accessPath'];
    final dictionaries = raw['dictionaries'];
    if (accessPath is! String || accessPath.isEmpty || dictionaries is! List) {
      throw const FormatException(
          'Android returned an incomplete dictionary selection.');
    }
    return AndroidDictionarySelection(
      accessPath: accessPath,
      dictionaries: _parseAndroidSources(dictionaries),
    );
  }

  /// Uses iOS's document picker in open-in-place mode. The native adapter
  /// starts the folder's security-scoped access before returning the path and
  /// saves a bookmark that can be restored after the process is relaunched.
  Future<IosDictionarySelection?> pickIosDictionaryFolder(
      {String? initialDirectoryPath}) async {
    if (!Platform.isIOS) {
      return null;
    }
    final raw = await _channel.invokeMethod<Object>(
      'pickDictionaryFolder',
      <String, Object>{
        if (initialDirectoryPath != null)
          'initialDirectoryPath': initialDirectoryPath,
      },
    );
    if (raw == null) {
      return null;
    }
    // Accept the original string response so a hot-restarted Dart isolate can
    // still communicate with an older native runner during development.
    if (raw is String && raw.isNotEmpty) {
      return IosDictionarySelection(
        path: raw,
        wasCopiedIntoDictionaryHome: false,
      );
    }
    if (raw is! Map<Object?, Object?>) {
      throw const FormatException(
        'iOS returned an invalid dictionary folder selection.',
      );
    }
    final path = raw['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException(
        'iOS returned an incomplete dictionary folder selection.',
      );
    }
    return IosDictionarySelection(
      path: path,
      wasCopiedIntoDictionaryHome: raw['wasCopiedIntoDictionaryHome'] == true,
    );
  }

  /// Re-scans an already approved Android folder without showing the picker.
  ///
  /// This repairs libraries imported by earlier builds which remembered the
  /// MDX URI but not every numbered MDD volume. Oxford's audio is commonly
  /// split across `name.mdd`, `name.1.mdd`, and later volumes, so keeping only
  /// the base MDD lets an article render while individual pronunciations fail.
  Future<List<AndroidDictionarySource>> scanAndroidDictionaryFolder(
    String accessPath, {
    bool refresh = false,
  }) async {
    if (refresh) {
      _androidFolderScans.remove(accessPath);
    }
    final scan = _androidFolderScans.putIfAbsent(accessPath, () async {
      final raw = await _channel.invokeMethod<Object>(
        'scanDictionaryFolder',
        <String, Object>{'accessPath': accessPath},
      );
      if (raw is! List) {
        throw const FormatException(
          'Android returned an invalid dictionary folder scan.',
        );
      }
      return _parseAndroidSources(raw);
    });
    return scan;
  }

  List<AndroidDictionarySource> _parseAndroidSources(List<Object?> items) {
    final sources = <AndroidDictionarySource>[];
    for (final item in items) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }
      final mdxPath = item['mdxPath'];
      final rawMddPaths = item['mddPaths'];
      final rawSidecarResources = item['sidecarResources'];
      final relativePath = item['relativePath'];
      final sourceVersion = item['sourceVersion'];
      if (mdxPath is! String || mdxPath.isEmpty) {
        continue;
      }
      final mddPaths = rawMddPaths is List
          ? rawMddPaths
              .whereType<String>()
              .where((path) => path.isNotEmpty)
              .toList(
                growable: false,
              )
          : const <String>[];
      final sidecarResources = rawSidecarResources is List
          ? rawSidecarResources
              .map(DictionarySidecarResource.fromJson)
              .whereType<DictionarySidecarResource>()
              .toList(growable: false)
          : const <DictionarySidecarResource>[];
      sources.add(
        AndroidDictionarySource(
          mdxPath: mdxPath,
          relativePath: relativePath is String && relativePath.isNotEmpty
              ? relativePath
              : _contentUriFileName(mdxPath),
          sourceVersion: sourceVersion is String && sourceVersion.isNotEmpty
              ? sourceVersion
              : null,
          mddPaths: mddPaths,
          sidecarResources: sidecarResources,
        ),
      );
    }
    return List.unmodifiable(sources);
  }

  /// Registers the companion files paired with one Android MDX. Calling this
  /// is harmless on desktop and is required again after restoring the library.
  void registerSource(
    String mdxPath,
    List<String> mddPaths, {
    List<DictionarySidecarResource> sidecarResources =
        const <DictionarySidecarResource>[],
    String? accessPath,
  }) {
    if (!Platform.isAndroid || !_isContentUri(mdxPath)) {
      return;
    }
    final nextMddPaths = List<String>.unmodifiable(mddPaths);
    final nextSidecars =
        List<DictionarySidecarResource>.unmodifiable(sidecarResources);
    final previousMddPaths = _androidMddPaths[mdxPath];
    final previousSidecars = _androidSidecars[mdxPath];
    final previousAccessPath = _androidAccessPaths[mdxPath];
    final unchanged = previousMddPaths != null &&
        _sameStrings(previousMddPaths, nextMddPaths) &&
        previousSidecars != null &&
        _sameSidecars(previousSidecars, nextSidecars) &&
        (accessPath == null || accessPath == previousAccessPath);
    _androidMddPaths[mdxPath] = nextMddPaths;
    _androidSidecars[mdxPath] = nextSidecars;
    if (accessPath != null && _isContentUri(accessPath)) {
      _androidAccessPaths[mdxPath] = accessPath;
    }
    if (!unchanged) {
      _androidSources.remove(mdxPath);
      _androidResourceSources.remove(mdxPath);
    }
  }

  void unregisterSource(String mdxPath) {
    final mddPaths = _androidMddPaths.remove(mdxPath) ?? const <String>[];
    final sidecarResources =
        _androidSidecars.remove(mdxPath) ?? const <DictionarySidecarResource>[];
    _androidAccessPaths.remove(mdxPath);
    _androidSources.remove(mdxPath);
    _androidResourceSources.remove(mdxPath);
    _contentFingerprints.remove(mdxPath);
    if (!Platform.isAndroid) {
      return;
    }
    if (_isContentUri(mdxPath)) {
      unawaited(_removeAndroidSourceCache(mdxPath));
    }
    for (final uri in <String>[
      mdxPath,
      ...mddPaths,
      ...sidecarResources.map((resource) => resource.uri),
    ]) {
      unawaited(
        _channel.invokeMethod<void>(
            'closeReadHandle', <String, Object>{'uri': uri}),
      );
      unawaited(
        _channel.invokeMethod<void>(
            'removeLocalCopy', <String, Object>{'uri': uri}),
      );
    }
  }

  /// Drops work created while inspecting a duplicate candidate without
  /// closing MDD/CSS handles that may intentionally be shared by the retained
  /// dictionary package.
  void discardDuplicateSource(String mdxPath) {
    _androidMddPaths.remove(mdxPath);
    _androidSidecars.remove(mdxPath);
    _androidAccessPaths.remove(mdxPath);
    _androidSources.remove(mdxPath);
    _androidResourceSources.remove(mdxPath);
    _contentFingerprints.remove(mdxPath);
    if (!Platform.isAndroid || !_isContentUri(mdxPath)) return;
    unawaited(_removeAndroidSourceCache(mdxPath));
    unawaited(
      _channel.invokeMethod<void>(
        'closeReadHandle',
        <String, Object>{'uri': mdxPath},
      ),
    );
    unawaited(
      _channel.invokeMethod<void>(
        'removeLocalCopy',
        <String, Object>{'uri': mdxPath},
      ),
    );
  }

  /// Removes a private MDX copy after a successful tree scan proves that its
  /// original document is gone. The library row is intentionally retained so
  /// user naming, ordering and enablement choices are not silently erased.
  void discardUnavailableSource(String mdxPath) {
    discardDuplicateSource(mdxPath);
  }

  void invalidateMdxSource(String mdxPath) {
    _androidSources.remove(mdxPath);
    _androidResourceSources.remove(mdxPath);
    _contentFingerprints.remove(mdxPath);
  }

  Future<void> retain(String mdxPath) async {
    if (Platform.isAndroid) {
      // The folder picker persists the SAF grant before returning to Dart.
      return;
    }
    if (!Platform.isMacOS && !Platform.isIOS) {
      return;
    }
    final saved = await _channel.invokeMethod<bool>(
      'saveReadBookmark',
      <String, Object>{'path': mdxPath},
    );
    if (saved != true) {
      throw StateError(
          'Apple platform did not create a reusable read-access grant');
    }
  }

  Future<bool> restore(String mdxPath) async {
    if (Platform.isAndroid) {
      if (!_isContentUri(mdxPath)) {
        return File(mdxPath).exists();
      }
      return await _channel.invokeMethod<bool>(
            'hasReadGrant',
            <String, Object>{'uri': mdxPath},
          ) ??
          false;
    }
    if (!Platform.isMacOS && !Platform.isIOS) {
      return true;
    }
    return await _channel.invokeMethod<bool>(
          'restoreReadBookmark',
          <String, Object>{'path': mdxPath},
        ) ??
        false;
  }

  Future<void> revoke(String mdxPath) async {
    if (Platform.isAndroid) {
      // Do not revoke a folder-level SAF grant here: several imported MDX
      // files may share it. The system releases unused grants on uninstall;
      // the caller separately closes this dictionary's MDX/MDD descriptors by
      // their document URIs.
      return;
    }
    if (!Platform.isMacOS && !Platform.isIOS) {
      return;
    }
    await _channel.invokeMethod<void>(
      'revokeReadBookmark',
      <String, Object>{'path': mdxPath},
    );
  }

  /// Resolves the MDX content URI to a stable private performance copy.
  /// Resource companion files are deliberately prepared separately by
  /// [resolveMdxPathForResources].
  Future<String> resolveMdxPath(String mdxPath) async {
    if (!Platform.isAndroid || !_isContentUri(mdxPath)) {
      return mdxPath;
    }
    final source = _androidSources.putIfAbsent(
      mdxPath,
      () => _resolveAndroidSource(mdxPath),
    );
    return (await source).mdxPath;
  }

  /// Returns a cheap identity for a directly readable MDX. iOS uses this to
  /// notice that a file was replaced in place without hashing every dictionary
  /// on every foreground scan. Android gets the equivalent provider metadata
  /// from its SAF tree scan instead.
  Future<String?> sourceVersionForMdx(String mdxPath) async {
    if (Platform.isAndroid && _isContentUri(mdxPath)) return null;
    return _localFileVersion(mdxPath);
  }

  /// Computes a stable content identity without loading the whole MDX into
  /// memory. Android hashes the validated private source copy, so a provider
  /// stream is never consumed twice concurrently. The path cache is tied to
  /// file size and modification time so replacing an iOS MDX in place cannot
  /// leave an obsolete content identity behind.
  Future<String> fingerprintMdx(String mdxPath) async {
    final resolvedPath = await resolveMdxPath(mdxPath);
    final sourceVersion = await _localFileVersion(resolvedPath);
    final existing = _contentFingerprints[mdxPath];
    if (existing != null && existing.sourceVersion == sourceVersion) {
      return existing.value;
    }
    final value = () async {
      final digest = await sha256.bind(File(resolvedPath).openRead()).first;
      return 'sha256:$digest';
    }();
    final cached = _CachedContentFingerprint(
      sourceVersion: sourceVersion,
      value: value,
    );
    _contentFingerprints[mdxPath] = cached;
    try {
      return await value;
    } catch (_) {
      if (identical(_contentFingerprints[mdxPath], cached)) {
        _contentFingerprints.remove(mdxPath);
      }
      rethrow;
    }
  }

  Future<String> _localFileVersion(String path) async {
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Dictionary source is not a file', path);
    }
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  /// Adds MDD volumes and publisher sidecars to an already resolved Android
  /// source only when an article requests one. This is deliberately separate
  /// from [resolveMdxPath]: headword import, key indexing, lookup, and
  /// suggestions require only the MDX and should never wait for a huge audio
  /// archive to be staged from a stream-only DocumentsProvider. The native
  /// stager preserves the original document timestamp, keeping derived MDX
  /// and article caches valid across application restarts.
  Future<String> resolveMdxPathForResources(String mdxPath) async {
    if (!Platform.isAndroid || !_isContentUri(mdxPath)) {
      return mdxPath;
    }
    final existing = _androidResourceSources[mdxPath];
    if (existing != null) {
      return (await existing).mdxPath;
    }

    final preparation = _resolveAndroidResources(mdxPath);
    _androidResourceSources[mdxPath] = preparation;
    try {
      return (await preparation).mdxPath;
    } catch (_) {
      if (identical(_androidResourceSources[mdxPath], preparation)) {
        _androidResourceSources.remove(mdxPath);
      }
      rethrow;
    }
  }

  Future<_AndroidResolvedSource> _resolveAndroidSource(String mdxUri) async {
    final sourceDirectory = await _androidSourceDirectory(mdxUri);
    await sourceDirectory.create(recursive: true);

    // SAF descriptor performance differs dramatically across vendors and
    // storage providers. A one-time private MDX copy gives Rust a normal file
    // with predictable random access, matching dedicated mobile readers.
    final mdx = await _openAndroidDocument(mdxUri, preferLocalCopy: true);
    final mdxSource = await _createReadOnlyLink(
      sourceDirectory: sourceDirectory,
      document: mdx,
      fallbackName: 'dictionary.mdx',
    );
    final stagedSourceMarker = File(
      '${sourceDirectory.path}${Platform.pathSeparator}'
      '.lumalex-saf-staged-source',
    );
    if (mdx.isStaged) {
      // The marker lets the Rust resource resolver distinguish our private,
      // staged SAF source folder from a normal user-selected folder. Some
      // companion files may remain descriptor links while others are staged.
      await stagedSourceMarker.writeAsString('staged');
    } else if (await stagedSourceMarker.exists()) {
      await stagedSourceMarker.delete();
    }
    return _AndroidResolvedSource(mdxPath: mdxSource.path);
  }

  Future<_AndroidResolvedSource> _resolveAndroidResources(String mdxUri) async {
    final mdx =
        await (_androidSources[mdxUri] ??= _resolveAndroidSource(mdxUri));
    await _refreshAndroidCompanions(mdxUri);
    final sourceDirectory = await _androidSourceDirectory(mdxUri);
    await sourceDirectory.create(recursive: true);

    for (final (index, uri)
        in (_androidMddPaths[mdxUri] ?? const <String>[]).indexed) {
      final mdd = await _openAndroidDocument(uri);
      await _createReadOnlyLink(
        sourceDirectory: sourceDirectory,
        document: mdd,
        fallbackName: index == 0 ? 'dictionary.mdd' : 'dictionary.$index.mdd',
      );
    }
    for (final sidecar
        in _androidSidecars[mdxUri] ?? const <DictionarySidecarResource>[]) {
      final resource = await _openAndroidDocument(sidecar.uri);
      await _createReadOnlyLink(
        sourceDirectory: sourceDirectory,
        document: resource,
        fallbackName: 'resource.bin',
        relativePath: sidecar.relativePath,
      );
    }
    return mdx;
  }

  Future<Directory> _androidSourceDirectory(String mdxUri) async {
    final cacheDirectory = await getApplicationCacheDirectory();
    return Directory(
      '${cacheDirectory.path}${Platform.pathSeparator}saf-sources'
      '${Platform.pathSeparator}${_stableDirectoryName(mdxUri)}',
    );
  }

  Future<void> _removeAndroidSourceCache(String mdxUri) async {
    try {
      final directory = await _androidSourceDirectory(mdxUri);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Cache cleanup must never interfere with removing a dictionary's
      // persisted source metadata or access descriptors.
    }
  }

  Future<void> _refreshAndroidCompanions(String mdxUri) async {
    // A fresh folder import and every current library record already retain
    // the full MDD list. Re-walking a large SAF tree on the first image or
    // pronunciation request can take seconds on physical phones, and gives
    // no new information. Only older records without companion metadata need
    // this repair scan.
    if (_androidMddPaths.containsKey(mdxUri) ||
        _androidSidecars.containsKey(mdxUri)) {
      return;
    }
    final accessPath = _androidAccessPaths[mdxUri];
    if (accessPath == null) {
      return;
    }
    try {
      final sources = await scanAndroidDictionaryFolder(accessPath);
      final source =
          sources.where((candidate) => candidate.mdxPath == mdxUri).firstOrNull;
      if (source == null) {
        return;
      }
      _androidMddPaths[mdxUri] = source.mddPaths;
      _androidSidecars[mdxUri] = source.sidecarResources;
    } catch (_) {
      // The previously persisted source remains usable if a provider no
      // longer permits a background scan. Importing a new folder still gives
      // the user a way to refresh the grant explicitly.
    }
  }

  Future<({String path, String name, bool isStaged})> _openAndroidDocument(
    String uri, {
    bool preferLocalCopy = false,
  }) async {
    final raw = await _channel.invokeMethod<Object>(
      'openReadHandle',
      <String, Object>{
        'uri': uri,
        'preferLocalCopy': preferLocalCopy,
      },
    );
    if (raw is! Map<Object?, Object?> ||
        raw['path'] is! String ||
        raw['name'] is! String) {
      throw FileSystemException(
          'Android could not open this dictionary document.');
    }
    return (
      path: raw['path']! as String,
      name: raw['name']! as String,
      isStaged: raw['staged'] == true,
    );
  }

  Future<FileSystemEntity> _createReadOnlyLink({
    required Directory sourceDirectory,
    required ({String path, String name, bool isStaged}) document,
    required String fallbackName,
    String? relativePath,
  }) async {
    final parts = _safeRelativePath(relativePath) ??
        <String>[_safeFileName(document.name, fallbackName)];
    final parent = parts.length > 1
        ? Directory(
            '${sourceDirectory.path}${Platform.pathSeparator}'
            '${parts.take(parts.length - 1).join(Platform.pathSeparator)}',
          )
        : sourceDirectory;
    await parent.create(recursive: true);
    final targetPath = '${parent.path}${Platform.pathSeparator}${parts.last}';
    final existing =
        await FileSystemEntity.type(targetPath, followLinks: false);
    if (existing == FileSystemEntityType.file) {
      await File(targetPath).delete();
    } else if (existing == FileSystemEntityType.link) {
      await Link(targetPath).delete();
    } else if (existing != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'An unsupported filesystem entry already occupies this dictionary path.',
        targetPath,
      );
    }
    if (document.isStaged) {
      // The native staging file is stable across launches and validated
      // against the provider's size/timestamp. Link it into the per-dictionary
      // resource directory instead of moving or duplicating hundreds of MB.
      final link = Link(targetPath);
      await link.create(document.path);
      return link;
    }
    final link = Link(targetPath);
    await link.create(document.path);
    return link;
  }

  bool _isContentUri(String path) => path.startsWith('content://');

  String _contentUriFileName(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.pathSegments.isEmpty) return value;
    final documentId = Uri.decodeComponent(uri.pathSegments.last);
    final slash = documentId.lastIndexOf('/');
    return slash < 0 ? documentId : documentId.substring(slash + 1);
  }

  bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  bool _sameSidecars(
    List<DictionarySidecarResource> left,
    List<DictionarySidecarResource> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].uri != right[index].uri ||
          left[index].relativePath != right[index].relativePath) {
        return false;
      }
    }
    return true;
  }

  String _safeFileName(String value, String fallback) {
    final sanitized = value.replaceAll(RegExp(r'[\\/]'), '_').trim();
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return fallback;
    }
    // Some physical-device DocumentsProvider implementations do not answer
    // the OpenableColumns name query for a tree child and native code has to
    // fall back to `dictionary.bin`. Preserve the known MDX/MDD extension so
    // the Rust reader can still validate and pair the source files.
    final expectedExtension = fallback.split('.').last.toLowerCase();
    final extension =
        sanitized.contains('.') ? sanitized.split('.').last.toLowerCase() : '';
    return extension == expectedExtension ? sanitized : fallback;
  }

  List<String>? _safeRelativePath(String? value) {
    if (value == null ||
        value.isEmpty ||
        value.startsWith('/') ||
        value.contains('\\')) {
      return null;
    }
    final parts = value.split('/');
    if (parts.any(
      (part) => part.isEmpty || part == '.' || part == '..',
    )) {
      return null;
    }
    return parts;
  }

  String _stableDirectoryName(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
