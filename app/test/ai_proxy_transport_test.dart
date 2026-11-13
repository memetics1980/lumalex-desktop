import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/ai_proxy.dart';
import 'package:local_dictionary/services/screen_lookup_ai.dart';

// These deliberately public, self-signed fixtures are for local tests only.
// Production HttpClient certificate validation is never replaced or disabled.
void main() {
  final cert = File('test/fixtures/ai_proxy/test-cert.pem.txt').absolute.path;
  final key = File('test/fixtures/ai_proxy/test-key.pem.txt').absolute.path;
  const apiHost = 'ai-proxy-test.invalid';

  for (final mode in [AiProxyMode.manual, AiProxyMode.system]) {
    test('AI request traverses HTTP CONNECT with verified TLS (${mode.name})',
        () async {
      final tlsContext = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4, 0, tlsContext);
      addTearDown(() => origin.close(force: true));
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final sockets = <Socket>[];
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final tunnels = <String>[];
      final connectHeaders = <String>[];
      final transportErrors = <Object>[];
      final proxySubscription = proxy.listen((request) async {
        try {
          tunnels.add('${request.method} ${request.uri}');
          connectHeaders.add(request.headers.toString());
          final upstream =
              await Socket.connect(InternetAddress.loopbackIPv4, origin.port);
          sockets.add(upstream);
          final downstream =
              await request.response.detachSocket(writeHeaders: false);
          sockets.add(downstream);
          downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          await downstream.flush();
          unawaited(upstream
              .cast<List<int>>()
              .pipe(downstream)
              .catchError((Object error) {
            transportErrors.add(error);
          }));
          unawaited(downstream
              .cast<List<int>>()
              .pipe(upstream)
              .catchError((Object error) {
            transportErrors.add(error);
          }));
        } catch (error) {
          transportErrors.add(error);
        }
      });
      addTearDown(proxySubscription.cancel);
      final received = Completer<Map<String, Object?>>();
      final originSubscription = origin.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, Object?>;
        received.complete({
          'path': request.uri.path,
          'authorization':
              request.headers.value(HttpHeaders.authorizationHeader),
          'body': body,
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'lemma': 'offer',
                  'chineseMeaning': '提供',
                  'englishMeaning': 'to provide',
                  'evidence': 'offer care',
                  'confidence': 'high',
                })
              }
            }
          ],
        }));
        await request.response.close();
      });
      addTearDown(originSubscription.cancel);
      final client = ScreenLookupAiClient(
        createClient: () => HttpClient(
            context: SecurityContext()
              ..setTrustedCertificates(
                  'test/fixtures/ai_proxy/test-ca.pem.txt')),
        proxyResolver: AiProxyResolver(
            environment: {},
            loadSystemProxy: (_) async =>
                {'server': '127.0.0.1:${proxy.port}'}),
      );
      final result = await client.analyze(
        settings: ScreenLookupAiSettings(
            baseUrl: 'https://$apiHost/v1',
            model: 'test-model',
            proxyMode: mode,
            proxyAddress: 'http://127.0.0.1:${proxy.port}'),
        apiKey: 'test-api-key',
        word: 'offer',
        context: 'They offer care.',
      );
      final request = await received.future;
      expect(tunnels, ['CONNECT $apiHost:443']);
      expect(connectHeaders.single, isNot(contains('test-api-key')));
      expect(request['path'], '/v1/chat/completions');
      expect(request['authorization'], 'Bearer test-api-key');
      expect((request['body'] as Map)['model'], 'test-model');
      expect(result.chineseMeaning, '提供');
      expect(transportErrors, isEmpty);
    });
  }

  test('unreachable proxy reports proxy route and does not try direct',
      () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(
        ScreenLookupAiClient().analyze(
          settings: ScreenLookupAiSettings(
              baseUrl: 'https://$apiHost/v1',
              model: 'test',
              proxyMode: AiProxyMode.manual,
              proxyAddress: '127.0.0.1:$port'),
          apiKey: 'test',
          word: 'offer',
          context: 'They offer care.',
        ),
        throwsA(isA<ScreenLookupAiException>().having((error) => error.message,
            'message', allOf(contains('HTTP 代理'), contains('端口')))));
  });

  test('CONNECT authentication failure has an actionable message', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final subscription = proxy.listen((request) async {
      request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
      request.response.headers.set('proxy-authenticate', 'Basic realm="test"');
      await request.response.close();
    });
    addTearDown(subscription.cancel);
    await expectLater(
        ScreenLookupAiClient().analyze(
          settings: ScreenLookupAiSettings(
              baseUrl: 'https://$apiHost/v1',
              model: 'test',
              proxyMode: AiProxyMode.manual,
              proxyAddress: '127.0.0.1:${proxy.port}'),
          apiKey: 'test',
          word: 'offer',
          context: 'They offer care.',
        ),
        throwsA(isA<ScreenLookupAiException>()
            .having((error) => error.message, 'message', contains('代理认证'))));
  });
}
