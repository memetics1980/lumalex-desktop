import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_dictionary/screens/home_page.dart';
import 'package:local_dictionary/services/screen_lookup_ai.dart';

void main() {
  test('API keys accept single tokens and reject pasted notes or controls', () {
    expect(validateScreenLookupAiApiKey('  test-token_123  '), isNull);
    expect(validateScreenLookupAiApiKey('  '), contains('尚未配置'));
    for (final key in [
      'OpenAI api\r\rsk-test-secret',
      'sk-test\nsecret',
      'API Key: sk-test-secret',
      'sk-test\tsecret',
      'sk-test\u0000secret',
      'sk-test\u007fsecret',
      '密钥sk-test-secret',
    ]) {
      final error = validateScreenLookupAiApiKey(key);
      expect(error, contains('请只粘贴密钥本身'));
      expect(error, isNot(contains('sk-test')));
    }
  });

  test('malformed stored credentials fail safely before creating a connection',
      () async {
    var clientCreated = false;
    final client = ScreenLookupAiClient(createClient: () {
      clientCreated = true;
      return HttpClient();
    });
    await expectLater(
      client.analyze(
        settings: const ScreenLookupAiSettings(
            baseUrl: 'https://example.com/v1', model: 'test-model'),
        apiKey: 'OpenAI api\r\rsk-test-secret',
        word: 'offer',
        context: 'They offer care.',
      ),
      throwsA(isA<ScreenLookupAiException>().having(
          (error) => error.message,
          'message',
          allOf(contains('请只粘贴密钥本身'), isNot(contains('sk-test-secret'))))),
    );
    expect(clientCreated, isFalse);
  });

  test('AI endpoint appends chat completions and preserves query parameters',
      () {
    expect(
      screenLookupAiEndpoint('https://example.com/v1').toString(),
      'https://example.com/v1/chat/completions',
    );
    expect(
      screenLookupAiEndpoint(
        'https://example.com/v1/chat/completions?api-version=1',
      ).toString(),
      'https://example.com/v1/chat/completions?api-version=1',
    );
  });

  test('AI endpoint permits secure remote and local development services', () {
    expect(
        isAllowedScreenLookupAiBaseUrl('https://api.example.com/v1'), isTrue);
    expect(isAllowedScreenLookupAiBaseUrl('http://127.0.0.1:11434/v1'), isTrue);
    expect(isAllowedScreenLookupAiBaseUrl('http://localhost:1234/v1'), isTrue);
    expect(
        isAllowedScreenLookupAiBaseUrl('http://api.example.com/v1'), isFalse);
    expect(isAllowedScreenLookupAiBaseUrl('file:///tmp/model'), isFalse);
  });

  test('AI result parser accepts fenced JSON and normalizes fields', () {
    final result = parseScreenLookupAiContent('''```json
{
  "lemma": "offer",
  "partOfSpeech": "verb",
  "englishMeaning": "to provide something",
  "chineseMeaning": "提供；给予",
  "evidence": "can offer the specialized care",
  "confidence": "HIGH",
  "ambiguityNote": ""
}
```''');

    expect(result.lemma, 'offer');
    expect(result.chineseMeaning, '提供；给予');
    expect(result.confidence, 'high');
  });

  test('AI result parser rejects a response without a usable meaning', () {
    expect(
      () => parseScreenLookupAiContent(
        '{"lemma":"offer","partOfSpeech":"verb"}',
      ),
      throwsA(isA<ScreenLookupAiException>()),
    );
  });

  test('AI popup payload preserves Unicode through base64', () {
    final payload = <String, Object?>{
      'status': 'success',
      'chineseMeaning': '提供；给予',
    };
    final encoded = encodeScreenLookupAiPayload(payload);
    expect(jsonDecode(utf8.decode(base64Decode(encoded))), payload);
  });

  test('AI client sends context and parses an OpenAI-compatible response',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late String requestPath;
    late String authorization;
    late Map<Object?, Object?> requestBody;
    final handled = server.first.then((request) async {
      requestPath = request.uri.path;
      authorization =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      requestBody = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<Object?, Object?>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'choices': <Object>[
            <String, Object>{
              'message': <String, String>{
                'content': jsonEncode(<String, String>{
                  'lemma': 'offer',
                  'partOfSpeech': 'verb',
                  'englishMeaning': 'to provide',
                  'chineseMeaning': '提供',
                  'evidence': 'can offer care',
                  'confidence': 'high',
                  'ambiguityNote': '',
                }),
              },
            },
          ],
        }),
      );
      await request.response.close();
    });

    final result = await ScreenLookupAiClient().analyze(
      settings: ScreenLookupAiSettings(
        enabled: true,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
      ),
      apiKey: 'test-key',
      word: 'offer',
      context: 'Providers can offer care.',
    );
    await handled;

    expect(requestPath, '/v1/chat/completions');
    expect(authorization, 'Bearer test-key');
    expect(requestBody['model'], 'test-model');
    expect(requestBody['max_completion_tokens'], 4096);
    expect(requestBody.containsKey('max_tokens'), isFalse);
    expect(requestBody.containsKey('temperature'), isFalse);
    expect(result.chineseMeaning, '提供');
  });

  test(
      'legacy providers get one fallback after explicit token parameter rejection',
      () async {
    final fixture = await _mockAi([
      (
        status: 400,
        body: {
          'error': {
            'code': 'unsupported_parameter',
            'param': 'max_completion_tokens',
            'message':
                "Unsupported parameter: 'max_completion_tokens'. Use 'max_tokens' instead.",
          }
        }
      ),
      (status: 200, body: _successfulAiBody()),
    ]);
    expect((await fixture.analyze()).chineseMeaning, '提供');
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests[0]['max_completion_tokens'], 4096);
    expect(fixture.requests[0].containsKey('max_tokens'), isFalse);
    expect(fixture.requests[1]['max_tokens'], 420);
    expect(fixture.requests[1].containsKey('max_completion_tokens'), isFalse);
    expect(fixture.requests[0]['messages'], fixture.requests[1]['messages']);
    expect(fixture.requests[1].containsKey('temperature'), isFalse);
  });

  test('message-only legacy parameter errors also negotiate once', () async {
    final fixture = await _mockAi([
      (
        status: 422,
        body: {
          'message': 'Unrecognized request argument: max_completion_tokens'
        }
      ),
      (status: 200, body: _successfulAiBody()),
    ]);
    expect((await fixture.analyze()).chineseMeaning, '提供');
    expect(fixture.requests, hasLength(2));
  });

  for (final status in [401, 403, 429, 500]) {
    test(
        'HTTP $status is never retried even if its message names a token parameter',
        () async {
      final fixture = await _mockAi([
        (
          status: status,
          body: {
            'error': {
              'code': 'unsupported_parameter',
              'param': 'max_completion_tokens',
              'message': 'Unsupported max_completion_tokens',
            }
          }
        ),
      ]);
      await expectLater(
          fixture.analyze(), throwsA(isA<ScreenLookupAiException>()));
      expect(fixture.requests, hasLength(1));
    });
  }

  test('invalid token budget errors are preserved without changing parameters',
      () async {
    const message = 'max_completion_tokens must be less than or equal to 1024';
    final fixture = await _mockAi([
      (
        status: 400,
        body: {
          'error': {
            'code': 'invalid_value',
            'param': 'max_completion_tokens',
            'message': message
          }
        }
      ),
    ]);
    await expectLater(
        fixture.analyze(),
        throwsA(isA<ScreenLookupAiException>()
            .having((error) => error.message, 'message', message)));
    expect(fixture.requests, hasLength(1));
  });

  test('an incompatible provider cannot create an unbounded retry loop',
      () async {
    final fixture = await _mockAi([
      (
        status: 400,
        body: {
          'error': {'message': 'Unsupported parameter: max_completion_tokens'}
        }
      ),
      (
        status: 400,
        body: {
          'error': {
            'message':
                "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
          }
        }
      ),
    ]);
    await expectLater(
        fixture.analyze(), throwsA(isA<ScreenLookupAiException>()));
    expect(fixture.requests, hasLength(2));
  });

  test(
      'a suggested modern token parameter is not mistaken for the rejected one',
      () async {
    final fixture = await _mockAi([
      (
        status: 400,
        body: {
          'error': {
            'message':
                "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
          }
        }
      ),
    ]);
    await expectLater(
        fixture.analyze(), throwsA(isA<ScreenLookupAiException>()));
    expect(fixture.requests, hasLength(1));
  });

  test('truncated reasoning completion has a clear error and is not retried',
      () async {
    final fixture = await _mockAi([
      (
        status: 200,
        body: {
          'choices': [
            {
              'finish_reason': 'length',
              'message': {'content': ''}
            }
          ]
        }
      ),
    ]);
    await expectLater(
        fixture.analyze(),
        throwsA(isA<ScreenLookupAiException>()
            .having((error) => error.message, 'message', contains('推理长度上限'))));
    expect(fixture.requests, hasLength(1));
  });
}

Map<String, Object> _successfulAiBody() => {
      'choices': [
        {
          'message': {
            'content': jsonEncode({
              'lemma': 'offer',
              'chineseMeaning': '提供',
              'englishMeaning': 'to provide',
              'confidence': 'high',
            })
          }
        }
      ],
    };

Future<
    ({
      Future<ScreenLookupAiResult> Function() analyze,
      List<Map<String, Object?>> requests
    })> _mockAi(
  List<({int status, Object body})> replies,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final requests = <Map<String, Object?>>[];
  final subscription = server.listen((request) async {
    requests.add(jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, Object?>);
    final index = requests.length - 1;
    final reply = replies[index < replies.length ? index : replies.length - 1];
    request.response.statusCode = reply.status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply.body));
    await request.response.close();
  });
  addTearDown(subscription.cancel);
  return (
    analyze: () => ScreenLookupAiClient().analyze(
          settings: ScreenLookupAiSettings(
              baseUrl: 'http://127.0.0.1:${server.port}/v1',
              model: 'provider/custom-model'),
          apiKey: 'test-key',
          word: 'offer',
          context: 'They offer care.',
        ),
    requests: requests,
  );
}
