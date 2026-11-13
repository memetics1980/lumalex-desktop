import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_proxy.dart';

const defaultScreenLookupAiBaseUrl = 'https://openrouter.ai/api/v1';

final class ScreenLookupAiSettings {
  const ScreenLookupAiSettings({
    this.enabled = false,
    this.baseUrl = defaultScreenLookupAiBaseUrl,
    this.model = '',
    this.proxyMode = AiProxyMode.system,
    this.proxyAddress = '',
  });

  final bool enabled;
  final String baseUrl;
  final String model;
  final AiProxyMode proxyMode;
  final String proxyAddress;

  bool configured({required bool apiKeyPresent}) =>
      enabled &&
      apiKeyPresent &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;
}

final class ScreenLookupAiResult {
  const ScreenLookupAiResult({
    required this.lemma,
    required this.partOfSpeech,
    required this.englishMeaning,
    required this.chineseMeaning,
    required this.evidence,
    required this.confidence,
    required this.ambiguityNote,
  });

  final String lemma;
  final String partOfSpeech;
  final String englishMeaning;
  final String chineseMeaning;
  final String evidence;
  final String confidence;
  final String ambiguityNote;

  Map<String, String> toJson() => <String, String>{
        'lemma': lemma,
        'partOfSpeech': partOfSpeech,
        'englishMeaning': englishMeaning,
        'chineseMeaning': chineseMeaning,
        'evidence': evidence,
        'confidence': confidence,
        'ambiguityNote': ambiguityNote,
      };
}

final class ScreenLookupAiException implements Exception {
  const ScreenLookupAiException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool isAllowedScreenLookupAiBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host.endsWith('.localhost');
}

Uri screenLookupAiEndpoint(String baseUrl) {
  if (!isAllowedScreenLookupAiBaseUrl(baseUrl)) {
    throw const ScreenLookupAiException(
      'API 地址必须使用 HTTPS；本机服务可以使用 localhost 或 127.0.0.1。',
    );
  }
  final uri = Uri.parse(baseUrl.trim());
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/chat/completions')) return uri;
  return uri.replace(path: '$path/chat/completions');
}

ScreenLookupAiResult parseScreenLookupAiContent(String content) {
  var source = content.trim();
  if (source.startsWith('```')) {
    source = source.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
    source = source.replaceFirst(RegExp(r'\s*```$'), '');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw const ScreenLookupAiException('AI 返回的内容不是有效 JSON，请重试或更换模型。');
  }
  if (decoded is! Map<Object?, Object?>) {
    throw const ScreenLookupAiException('AI 返回的数据结构不正确。');
  }
  final data = decoded;

  String field(String key, {int maximumLength = 600}) {
    final value = data[key];
    if (value is! String) return '';
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= maximumLength
        ? normalized
        : normalized.substring(0, maximumLength);
  }

  final result = ScreenLookupAiResult(
    lemma: field('lemma', maximumLength: 80),
    partOfSpeech: field('partOfSpeech', maximumLength: 80),
    englishMeaning: field('englishMeaning'),
    chineseMeaning: field('chineseMeaning'),
    evidence: field('evidence'),
    confidence: field('confidence', maximumLength: 20).toLowerCase(),
    ambiguityNote: field('ambiguityNote'),
  );
  if (result.chineseMeaning.isEmpty && result.englishMeaning.isEmpty) {
    throw const ScreenLookupAiException('AI 没有返回可用的本句义项。');
  }
  return result;
}

final class ScreenLookupAiClient {
  ScreenLookupAiClient({
    HttpClient Function()? createClient,
    AiProxyResolver? proxyResolver,
  })  : _createClient = createClient ?? HttpClient.new,
        _proxyResolver = proxyResolver ?? AiProxyResolver();

  static const _timeout = Duration(seconds: 25);
  static const _maximumResponseBytes = 512 * 1024;

  final HttpClient Function() _createClient;
  final AiProxyResolver _proxyResolver;

  Future<ScreenLookupAiResult> analyze({
    required ScreenLookupAiSettings settings,
    required String apiKey,
    required String word,
    required String context,
  }) async {
    final cleanWord = word.trim();
    final cleanContext = context.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleanWord.isEmpty || cleanContext.isEmpty) {
      throw const ScreenLookupAiException('没有读取到足够的上下文，无法判断本句义项。');
    }
    if (apiKey.trim().isEmpty) {
      throw const ScreenLookupAiException('尚未配置 API Key。');
    }
    if (settings.model.trim().isEmpty) {
      throw const ScreenLookupAiException('尚未配置模型名称。');
    }
    final endpoint = screenLookupAiEndpoint(settings.baseUrl);
    final client = _createClient()
      ..connectionTimeout = const Duration(seconds: 10);
    var route = '代理配置';
    try {
      final directive = await _proxyResolver.resolve(
        endpoint,
        settings.proxyMode,
        settings.proxyAddress,
      );
      route = directive == 'DIRECT' ? '直连' : 'HTTP 代理';
      client.findProxy = (_) => directive;
      final payload = <String, Object>{
        'model': settings.model.trim(),
        'max_completion_tokens': 4096,
        'messages': <Map<String, String>>[
          const <String, String>{
            'role': 'system',
            'content':
                '''You are a contextual dictionary assistant. Determine only the meaning used in the supplied context. Do not invent facts. Return one JSON object and no markdown with exactly these string fields: lemma, partOfSpeech, englishMeaning, chineseMeaning, evidence, confidence, ambiguityNote. evidence must quote a short phrase from the supplied context. confidence must be high, medium, or low. If context is insufficient, explain that in ambiguityNote and use low confidence.''',
          },
          <String, String>{
            'role': 'user',
            'content': jsonEncode(<String, String>{
              'selectedWord': cleanWord,
              'context': cleanContext,
            }),
          },
        ],
      };
      var response = await _postCompletion(client, endpoint, apiKey, payload);
      // Retry only an explicit parameter rejection, never authentication,
      // quota, network errors, or a completion that may already be billable.
      if (_requiresLegacyTokenLimit(response.statusCode, response.body)) {
        payload.remove('max_completion_tokens');
        payload['max_tokens'] = 420;
        response = await _postCompletion(client, endpoint, apiKey, payload);
      }
      final body = response.body;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var message = 'AI 请求失败（HTTP ${response.statusCode}）。';
        if (body is Map<Object?, Object?>) {
          final error = body['error'];
          if (error is Map<Object?, Object?> && error['message'] is String) {
            message = (error['message'] as String).trim();
          } else if (body['message'] is String) {
            message = (body['message'] as String).trim();
          }
        }
        throw ScreenLookupAiException(message);
      }
      if (body is! Map<Object?, Object?> || body['choices'] is! List<Object?>) {
        throw const ScreenLookupAiException('AI 接口返回的数据结构不兼容。');
      }
      final choices = body['choices'] as List<Object?>;
      if (choices.isEmpty || choices.first is! Map<Object?, Object?>) {
        throw const ScreenLookupAiException('AI 接口没有返回分析结果。');
      }
      final choice = choices.first as Map<Object?, Object?>;
      if (choice['finish_reason'] == 'length') {
        throw const ScreenLookupAiException(
          '模型已达到输出或推理长度上限，未返回完整释义。请使用推理开销较低的模型后重试。',
        );
      }
      final message = choice['message'];
      if (message is! Map<Object?, Object?> || message['content'] is! String) {
        throw const ScreenLookupAiException('AI 接口没有返回文本内容。');
      }
      return parseScreenLookupAiContent(message['content'] as String);
    } on ScreenLookupAiException {
      rethrow;
    } on AiProxyException catch (error) {
      throw ScreenLookupAiException(error.message);
    } on TimeoutException {
      throw ScreenLookupAiException('AI 请求超时（$route），请检查代理端口、网络或模型配置。');
    } on SocketException catch (error) {
      throw ScreenLookupAiException(
          '无法连接 AI 服务（$route）：${error.message}。请检查代理软件是否运行及 HTTP／混合端口是否正确。');
    } on HttpException {
      throw ScreenLookupAiException(
          'AI HTTP 连接失败（$route），请检查代理是否支持 HTTP CONNECT、端口是否正确，以及是否要求代理认证。');
    } on HandshakeException {
      throw const ScreenLookupAiException('AI 服务的 HTTPS 证书验证失败。');
    } finally {
      client.close(force: true);
    }
  }

  static bool _requiresLegacyTokenLimit(int status, Object? body) {
    if ((status != 400 && status != 422) || body is! Map<Object?, Object?>) {
      return false;
    }
    final error = body['error'];
    final details = error is Map<Object?, Object?> ? error : body;
    final messageValue = details['message'];
    final message = messageValue is String ? messageValue.toLowerCase() : '';
    // A suggested replacement can also appear in the error text. Only act on
    // the rejected parameter, rather than mistaking that suggestion for one.
    final parameter = details['param'];
    if (parameter != null && parameter != 'max_completion_tokens') return false;
    final namedParameter = RegExp(
      r'''(?:unsupported|unknown|unrecognized)\s+(?:request\s+)?(?:parameter|argument)(?:\s+supplied)?\s*:\s*['"]?([a-z_]+)''',
    ).firstMatch(message)?.group(1);
    if (namedParameter != null && namedParameter != 'max_completion_tokens') {
      return false;
    }

    if (details['param'] == 'max_completion_tokens' &&
        const [
          'unsupported_parameter',
          'unknown_parameter',
          'unrecognized_parameter'
        ].contains(details['code'])) {
      return true;
    }
    return message.contains('max_completion_tokens') &&
        const [
          'not supported',
          'unsupported',
          'unknown',
          'unrecognized',
          'not permitted',
          'not allowed',
          'unexpected keyword',
          '不支持',
          '未知参数'
        ].any(message.contains);
  }

  Future<({int statusCode, Object? body})> _postCompletion(
    HttpClient client,
    Uri endpoint,
    String apiKey,
    Map<String, Object> payload,
  ) async {
    final request = await client.postUrl(endpoint).timeout(_timeout);
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}')
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/json')
      ..headers.set(HttpHeaders.acceptHeader, 'application/json')
      ..headers.set(
          HttpHeaders.userAgentHeader, 'LumaLex/${Platform.operatingSystem}');
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close().timeout(_timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maximumResponseBytes) {
        throw const ScreenLookupAiException('AI 响应过大，已停止读取。');
      }
    }
    if (response.statusCode == HttpStatus.proxyAuthenticationRequired) {
      throw const ScreenLookupAiException(
        '代理要求身份验证（HTTP 407），请使用无需认证的本机 HTTP／混合代理端口。',
      );
    }
    try {
      return (
        statusCode: response.statusCode,
        body: jsonDecode(utf8.decode(bytes, allowMalformed: true))
      );
    } on FormatException {
      throw ScreenLookupAiException(
        'AI 接口返回了无法识别的响应（HTTP ${response.statusCode}）。',
      );
    }
  }
}
