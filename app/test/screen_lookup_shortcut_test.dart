import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/main.dart';
import 'package:local_dictionary/platform/windows_screen_lookup.dart';
import 'package:local_dictionary/screens/screen_lookup_shortcut_dialog.dart';
import 'package:local_dictionary/services/windows_app_settings.dart';

void main() {
  test('custom shortcuts round-trip and preserve old preset identifiers', () {
    final shortcut = WindowsScreenLookupShortcut.custom(
      modifiers: 7,
      virtualKey: 0x79,
    );
    expect(shortcut.windowsLabel, 'Ctrl + Alt + Shift + F10');
    expect(shortcut.macosLabel, '⌘ + ⌥ + ⇧ + F10');
    expect(windowsScreenLookupShortcutFromStorage(shortcut.name), shortcut);
    expect(WindowsScreenLookupShortcut.custom(modifiers: 3, virtualKey: 0x4c),
        WindowsScreenLookupShortcut.ctrlAltL);
    for (final preset in WindowsScreenLookupShortcut.values) {
      expect(windowsScreenLookupShortcutFromStorage(preset.name), preset);
    }
  });

  test('unsupported and corrupt shortcuts fall back safely', () {
    for (final value in [
      'custom:0:75',
      'custom:4:75',
      'custom:8:75',
      'custom:3:123',
      'custom:3:32',
      'custom:3:999',
      'custom:3:-75',
      'custom:3:75oops',
      'custom:2:67',
      'custom:2:86',
      'custom:1:115',
    ]) {
      expect(windowsScreenLookupShortcutFromStorage(value),
          WindowsScreenLookupShortcut.ctrlAltL,
          reason: value);
    }
    expect(
        () => WindowsScreenLookupShortcut.custom(modifiers: 4, virtualKey: 75),
        throwsArgumentError);
  });

  test('logical keys map to Windows letter, number and function keys', () {
    expect(WindowsScreenLookupShortcut.virtualKeyFor(LogicalKeyboardKey.keyZ),
        0x5a);
    expect(WindowsScreenLookupShortcut.virtualKeyFor(LogicalKeyboardKey.digit4),
        0x34);
    expect(WindowsScreenLookupShortcut.virtualKeyFor(LogicalKeyboardKey.f11),
        0x7a);
    expect(WindowsScreenLookupShortcut.virtualKeyFor(LogicalKeyboardKey.f12),
        isNull);
    expect(
        WindowsScreenLookupShortcut.virtualKeyFor(LogicalKeyboardKey.numpad1),
        isNull);
  });

  testWidgets('recorder rejects plain keys and accepts Ctrl Alt K',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: ScreenLookupShortcutDialog()));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('save-screen-lookup-shortcut')))
            .onPressed,
        isNull);
    await tester.sendKeyDownEvent((Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent((Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft));
    await tester.pump();
    expect(find.text(Platform.isMacOS ? '⌘ + ⌥ + K' : 'Ctrl + Alt + K'),
        findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('save-screen-lookup-shortcut')))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final conflict in [false, true]) {
    testWidgets(
        'custom setting ${conflict ? 'rolls back on conflict' : 'persists after recording'}',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final channel = MethodChannel(
          'local_dictionary/${Platform.isMacOS ? 'macos' : 'windows'}_screen_lookup');
      final lifecycle = MethodChannel(
          'local_dictionary/${Platform.isMacOS ? 'macos' : 'windows'}_window_lifecycle');
      final recordings = <bool>[];
      final configured = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycle, (_) async => null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        if (call.method == 'loadAiApiKey') return '';
        final arguments = call.arguments;
        if (call.method == 'setShortcutRecording') {
          recordings.add((arguments as Map)['recording'] as bool);
        }
        if (call.method == 'configure') {
          final shortcut = (arguments as Map)['shortcut'] as String;
          configured.add(shortcut);
          if (conflict && shortcut == 'custom:3:75') {
            throw PlatformException(code: 'hotkey_unavailable');
          }
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(lifecycle, null);
      });
      final settings =
          InMemoryWindowsAppSettingsStore(screenLookupEnabled: true);
      await tester.pumpWidget(DictionaryApp(windowsAppSettings: settings));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('settings-navigation-button')));
      await tester.pumpAndSettle();
      final customize =
          find.byKey(const ValueKey('custom-screen-lookup-shortcut'));
      await tester.ensureVisible(customize);
      await tester.pumpAndSettle();
      await tester.tap(customize);
      await tester.pumpAndSettle();
      expect(recordings, [true]);
      expect(find.byType(ScreenLookupShortcutDialog), findsOneWidget);
      await tester.sendKeyDownEvent((Platform.isMacOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent((Platform.isMacOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft));
      await tester.pump();
      await tester
          .tap(find.byKey(const ValueKey('save-screen-lookup-shortcut')));
      await tester.pumpAndSettle();
      expect(recordings, [true, false]);
      expect(configured, contains('custom:3:75'));
      expect(settings.screenLookupEnabled, isTrue);
      expect(
          settings.screenLookupShortcut,
          conflict
              ? WindowsScreenLookupShortcut.ctrlAltL
              : WindowsScreenLookupShortcut.custom(
                  modifiers: 3, virtualKey: 75));
      if (conflict) {
        expect(configured.last, 'ctrlAltL');
        expect(find.text('这个快捷键已被其他程序占用，请选择另一个。'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }, skip: !(Platform.isWindows || Platform.isMacOS));
  }

  testWidgets('recording cancellation resumes the shortcut without saving',
      (tester) async {
    WindowsScreenLookupShortcut? selected;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDialog<WindowsScreenLookupShortcut>(
                      context: context,
                      builder: (_) => const ScreenLookupShortcutDialog());
                },
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ScreenLookupShortcutDialog), findsNothing);
    expect(selected, isNull);
  });
}
