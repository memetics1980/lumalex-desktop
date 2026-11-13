import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/ai_proxy.dart';

void main() {
  final remote = Uri.parse('https://api.example.com/v1/chat/completions');

  test('HTTP proxy accepts mixed ports, optional scheme and IPv6', () {
    expect(httpAiProxyDirective('127.0.0.1:7890'), 'PROXY 127.0.0.1:7890');
    expect(httpAiProxyDirective('http://localhost:80'), 'PROXY localhost:80');
    expect(httpAiProxyDirective(' http://localhost:7897/ '),
        'PROXY localhost:7897');
    expect(httpAiProxyDirective('http://[::1]:7890'), 'PROXY [::1]:7890');
    for (final invalid in [
      '',
      'localhost',
      'http://host:0',
      'http://host:65536',
      'socks5://localhost:1080',
      'https://localhost:7890',
      'http://user:secret@localhost:7890',
      'http://host:7890/path',
      'http://host:7890?token=secret',
      'http://host:7890#fragment',
      'http://host:abc',
      'host:7890; DIRECT',
    ]) {
      expect(
          () => httpAiProxyDirective(invalid), throwsA(isA<AiProxyException>()),
          reason: invalid);
    }
  });

  test('Windows uses protocol-specific settings and bypass rules', () {
    expect(windowsAiProxyDirective(remote, {'server': '127.0.0.1:7890'}),
        'PROXY 127.0.0.1:7890');
    expect(
        windowsAiProxyDirective(
            remote, {'server': 'http=localhost:7890;https=localhost:7891'}),
        'PROXY localhost:7891');
    expect(windowsAiProxyDirective(remote, {'server': 'http=localhost:7890'}),
        'DIRECT');
    for (final pattern in ['*.example.com', 'api.example.com:443', '*']) {
      expect(
          windowsAiProxyDirective(
              remote, {'server': 'localhost:7890', 'bypass': pattern}),
          'DIRECT');
    }
    expect(
        windowsAiProxyDirective(Uri.parse('https://intranet/v1'),
            {'server': 'localhost:7890', 'bypass': '<local>'}),
        'DIRECT');
    expect(() => windowsAiProxyDirective(remote, {'autoConfig': true}),
        throwsA(isA<AiProxyException>()));
    expect(
        () =>
            windowsAiProxyDirective(remote, {'server': 'socks=localhost:1080'}),
        throwsA(isA<AiProxyException>()));
  });

  test('manual and direct modes override environment and system settings',
      () async {
    var loaded = false;
    final resolver = AiProxyResolver(
        environment: {'HTTPS_PROXY': 'localhost:9999'},
        loadSystemProxy: (_) async {
          loaded = true;
          return {};
        });
    expect(await resolver.resolve(remote, AiProxyMode.manual, 'localhost:7890'),
        'PROXY localhost:7890');
    expect(await resolver.resolve(remote, AiProxyMode.direct, ''), 'DIRECT');
    expect(loaded, isFalse);
    for (final host in [
      'localhost',
      '127.0.0.1',
      '127.0.0.2',
      '[::1]',
      'test.localhost'
    ]) {
      expect(
          await resolver.resolve(Uri.parse('https://$host/v1'),
              AiProxyMode.manual, 'localhost:7890'),
          'DIRECT');
    }
  });

  test('system settings are read anew and proxy failure cannot imply direct',
      () async {
    var port = 7890;
    final resolver = AiProxyResolver(
        environment: {},
        loadSystemProxy: (_) async => {'server': 'localhost:$port'});
    expect(await resolver.resolve(remote, AiProxyMode.system, ''),
        'PROXY localhost:7890');
    port = 7891;
    expect(await resolver.resolve(remote, AiProxyMode.system, ''),
        'PROXY localhost:7891');
    for (final config in [
      {'unsupported': 'PAC 自动'},
      {'unsupported': 'SOCKS'}
    ]) {
      final unsupported = AiProxyResolver(
          environment: {}, loadSystemProxy: (_) async => config);
      await expectLater(unsupported.resolve(remote, AiProxyMode.system, ''),
          throwsA(isA<AiProxyException>()));
    }
  });

  test('environment URLs and no_proxy are respected', () async {
    final resolver = AiProxyResolver(
        environment: {
          'https_proxy': 'http://localhost:7890',
          'HTTPS_PROXY': 'localhost:9999',
          'no_proxy': 'localhost,.internal.example.com',
        },
        loadSystemProxy: (_) async =>
            throw StateError('must not read native settings'));
    expect(await resolver.resolve(remote, AiProxyMode.system, ''),
        'PROXY localhost:7890');
    expect(
        await resolver.resolve(Uri.parse('https://a.internal.example.com'),
            AiProxyMode.system, ''),
        'DIRECT');
    final allProxy =
        AiProxyResolver(environment: {'ALL_PROXY': 'socks5://localhost:1080'});
    await expectLater(allProxy.resolve(remote, AiProxyMode.system, ''),
        throwsA(isA<AiProxyException>()));
  });

  test('missing or unknown stored mode defaults to system', () {
    expect(aiProxyModeFromStorage(null), AiProxyMode.system);
    expect(aiProxyModeFromStorage('unknown'), AiProxyMode.system);
    expect(aiProxyModeFromStorage('manual'), AiProxyMode.manual);
  });

  testWidgets('desktop bridge requests settings for the actual AI URL',
      (tester) async {
    final channel = MethodChannel(Platform.isMacOS
        ? 'local_dictionary/macos_screen_lookup'
        : 'local_dictionary/windows_screen_lookup');
    MethodCall? received;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      received = call;
      return {'server': 'localhost:7890'};
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final resolver = AiProxyResolver(environment: {});
    expect(await resolver.resolve(remote, AiProxyMode.system, ''),
        'PROXY localhost:7890');
    expect(received?.method, 'getAiProxySettings');
    expect(received?.arguments, {'url': remote.toString()});
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}
