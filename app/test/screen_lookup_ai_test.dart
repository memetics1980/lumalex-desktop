import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_dictionary/screens/home_page.dart';
import 'package:local_dictionary/services/screen_lookup_ai.dart';

void main() {
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
    expect(result.chineseMeaning, '提供');
  });
}
