import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:local_dictionary/platform/windows_window_lifecycle.dart';
import 'package:local_dictionary/platform/windows_screen_lookup.dart';
import 'package:local_dictionary/services/windows_app_settings.dart';

void main() {
  test('unknown close behavior safely defaults to direct exit', () {
    expect(
      windowsCloseBehaviorFromStorage(null),
      WindowsCloseBehavior.exitApp,
    );
    expect(
      windowsCloseBehaviorFromStorage('unexpected'),
      WindowsCloseBehavior.exitApp,
    );
    expect(
      windowsCloseBehaviorFromStorage('hideToTray'),
      WindowsCloseBehavior.hideToTray,
    );
  });

  test('in-memory Windows settings preserve tray and lookup choices', () async {
    final store = InMemoryWindowsAppSettingsStore();

    await store.saveCloseBehavior(WindowsCloseBehavior.hideToTray);
    await store.saveTrayNotificationShown(true);
    await store.saveScreenLookupEnabled(true);
    await store.saveScreenLookupShortcut(
      WindowsScreenLookupShortcut.ctrlShiftL,
    );
    await store.saveScreenLookupAiEnabled(true);
    await store.saveScreenLookupAiBaseUrl('https://example.com/v1');
    await store.saveScreenLookupAiModel('context-model');

    expect(
      await store.loadCloseBehavior(),
      WindowsCloseBehavior.hideToTray,
    );
    expect(await store.loadTrayNotificationShown(), isTrue);
    expect(await store.loadScreenLookupEnabled(), isTrue);
    expect(
      await store.loadScreenLookupShortcut(),
      WindowsScreenLookupShortcut.ctrlShiftL,
    );
    expect(await store.loadScreenLookupAiEnabled(), isTrue);
    expect(
      await store.loadScreenLookupAiBaseUrl(),
      'https://example.com/v1',
    );
    expect(await store.loadScreenLookupAiModel(), 'context-model');
  });

  test('unknown screen lookup shortcut safely uses Ctrl Alt L', () {
    expect(
      windowsScreenLookupShortcutFromStorage(null),
      WindowsScreenLookupShortcut.ctrlAltL,
    );
    expect(
      windowsScreenLookupShortcutFromStorage('unexpected'),
      WindowsScreenLookupShortcut.ctrlAltL,
    );
    expect(
      windowsScreenLookupShortcutFromStorage('altQ'),
      WindowsScreenLookupShortcut.altQ,
    );
  });

  testWidgets('window lifecycle sends the native tray configuration',
      (tester) async {
    const channel = MethodChannel('test/windows_window_lifecycle');
    MethodCall? received;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        received = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final lifecycle = WindowsWindowLifecycle(channel: channel);

    await lifecycle.configure(
      closeBehavior: WindowsCloseBehavior.hideToTray,
      showFirstHideNotification: true,
    );

    expect(received?.method, 'setCloseBehavior');
    expect(
      received?.arguments,
      <String, Object>{
        'behavior': 'hideToTray',
        'showFirstHideNotification': true,
      },
    );
  });

  testWidgets('screen lookup sends the native hotkey configuration',
      (tester) async {
    const channel = MethodChannel('test/windows_screen_lookup');
    MethodCall? received;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        received = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final lookup = WindowsScreenLookup(channel: channel);

    await lookup.configure(
      enabled: true,
      shortcut: WindowsScreenLookupShortcut.altQ,
    );

    expect(received?.method, 'configure');
    expect(
      received?.arguments,
      <String, Object>{'enabled': true, 'shortcut': 'altQ'},
    );
  });

  testWidgets('AI API key uses the native Windows credential bridge',
      (tester) async {
    const channel = MethodChannel('test/windows_ai_credentials');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        calls.add(call);
        if (call.method == 'loadAiApiKey') return 'secret-key';
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final lookup = WindowsScreenLookup(channel: channel);

    expect(await lookup.loadAiApiKey(), 'secret-key');
    await lookup.saveAiApiKey('replacement-key');
    await lookup.deleteAiApiKey();

    expect(calls.map((call) => call.method), [
      'loadAiApiKey',
      'saveAiApiKey',
      'deleteAiApiKey',
    ]);
    expect(
      calls[1].arguments,
      <String, Object>{'apiKey': 'replacement-key'},
    );
  });

  testWidgets('AI result bridge marks loading payloads as pending',
      (tester) async {
    const channel = MethodChannel('test/windows_ai_result');
    MethodCall? received;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        received = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final lookup = WindowsScreenLookup(channel: channel);

    await lookup.updateAiResult('encoded-payload', pending: true);

    expect(received?.method, 'updateAiResult');
    expect(
      received?.arguments,
      <String, Object>{
        'payload': 'encoded-payload',
        'pending': true,
      },
    );
  });
}
