import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

final class WindowsScreenLookupShortcut {
  const WindowsScreenLookupShortcut._(
      this.name, this.modifiers, this.virtualKey);

  static const ctrlAltL = WindowsScreenLookupShortcut._('ctrlAltL', 3, 0x4c);
  static const ctrlShiftL =
      WindowsScreenLookupShortcut._('ctrlShiftL', 6, 0x4c);
  static const altQ = WindowsScreenLookupShortcut._('altQ', 1, 0x51);
  static const values = [ctrlAltL, ctrlShiftL, altQ];

  // Modifier bits match Win32 MOD_ALT, MOD_CONTROL and MOD_SHIFT.
  final String name;
  final int modifiers;
  final int virtualKey;
  bool get isCustom => !values.contains(this);

  static bool isValidCombination(int modifiers, int key) =>
      modifiers > 0 &&
      modifiers < 8 &&
      (modifiers & 3) != 0 &&
      !(modifiers == 2 && [0x41, 0x43, 0x56, 0x58, 0x59, 0x5a].contains(key)) &&
      !(modifiers == 1 && key == 0x73) &&
      ((key >= 0x30 && key <= 0x39) ||
          (key >= 0x41 && key <= 0x5a) ||
          (key >= 0x70 && key <= 0x7a));

  factory WindowsScreenLookupShortcut.custom({
    required int modifiers,
    required int virtualKey,
  }) {
    if (!isValidCombination(modifiers, virtualKey)) {
      throw ArgumentError('Unsupported screen lookup shortcut');
    }
    for (final preset in values) {
      if (preset.modifiers == modifiers && preset.virtualKey == virtualKey) {
        return preset;
      }
    }
    return WindowsScreenLookupShortcut._(
      'custom:$modifiers:$virtualKey',
      modifiers,
      virtualKey,
    );
  }

  static int? virtualKeyFor(LogicalKeyboardKey key) {
    if (key.keyId >= LogicalKeyboardKey.keyA.keyId &&
        key.keyId <= LogicalKeyboardKey.keyZ.keyId) {
      return 0x41 + key.keyId - LogicalKeyboardKey.keyA.keyId;
    }
    if (key.keyId >= LogicalKeyboardKey.digit0.keyId &&
        key.keyId <= LogicalKeyboardKey.digit9.keyId) {
      return 0x30 + key.keyId - LogicalKeyboardKey.digit0.keyId;
    }
    if (key.keyId >= LogicalKeyboardKey.f1.keyId &&
        key.keyId <= LogicalKeyboardKey.f11.keyId) {
      return 0x70 + key.keyId - LogicalKeyboardKey.f1.keyId;
    }
    return null;
  }

  String get windowsLabel => [
        if ((modifiers & 2) != 0) 'Ctrl',
        if ((modifiers & 1) != 0) 'Alt',
        if ((modifiers & 4) != 0) 'Shift',
        virtualKey >= 0x70
            ? 'F${virtualKey - 0x70 + 1}'
            : String.fromCharCode(virtualKey),
      ].join(' + ');
  String get macosLabel => [
        if ((modifiers & 2) != 0) '⌘',
        if ((modifiers & 1) != 0) '⌥',
        if ((modifiers & 4) != 0) '⇧',
        virtualKey >= 0x70
            ? 'F${virtualKey - 0x70 + 1}'
            : String.fromCharCode(virtualKey),
      ].join(' + ');
  String get label => Platform.isMacOS
      ? switch (name) {
          'ctrlAltL' => '⌘ + ⌥ + L',
          'ctrlShiftL' => '⌘ + ⇧ + L',
          'altQ' => '⌥ + Q',
          _ => macosLabel,
        }
      : windowsLabel;

  @override
  bool operator ==(Object other) =>
      other is WindowsScreenLookupShortcut && name == other.name;
  @override
  int get hashCode => name.hashCode;
}

WindowsScreenLookupShortcut windowsScreenLookupShortcutFromStorage(
  String? value,
) {
  for (final preset in WindowsScreenLookupShortcut.values) {
    if (preset.name == value) return preset;
  }
  final match =
      RegExp(r'^custom:([1-7]):([0-9]{2,3})$').firstMatch(value ?? '');
  if (match != null) {
    final modifiers = int.parse(match.group(1)!);
    final key = int.parse(match.group(2)!);
    if (WindowsScreenLookupShortcut.isValidCombination(modifiers, key)) {
      return WindowsScreenLookupShortcut.custom(
        modifiers: modifiers,
        virtualKey: key,
      );
    }
  }
  return WindowsScreenLookupShortcut.ctrlAltL;
}

final class WindowsScreenLookupRequest {
  const WindowsScreenLookupRequest({
    required this.text,
    required this.context,
    required this.x,
    required this.y,
    required this.usedClipboardFallback,
  });

  final String text;
  final String context;
  final int x;
  final int y;
  final bool usedClipboardFallback;
}

typedef WindowsScreenLookupEventHandler = FutureOr<void> Function(
  String event,
  Map<Object?, Object?> arguments,
);

class WindowsScreenLookup {
  WindowsScreenLookup({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('local_dictionary/windows_screen_lookup');

  final MethodChannel _channel;

  void attach(WindowsScreenLookupEventHandler handler) =>
      _channel.setMethodCallHandler((call) async {
        final arguments = call.arguments;
        await handler(
          call.method,
          arguments is Map<Object?, Object?>
              ? arguments
              : const <Object?, Object?>{},
        );
      });

  void detach() => _channel.setMethodCallHandler(null);

  Future<void> configure({
    required bool enabled,
    required WindowsScreenLookupShortcut shortcut,
  }) =>
      _channel.invokeMethod<void>('configure', <String, Object>{
        'enabled': enabled,
        'shortcut': shortcut.name,
      });

  Future<void> showLoading(WindowsScreenLookupRequest request) =>
      _channel.invokeMethod<void>('showLoading', <String, Object>{
        'query': request.text,
        'x': request.x,
        'y': request.y,
      });

  Future<void> setShortcutRecording(bool recording) =>
      _channel.invokeMethod<void>('setShortcutRecording', <String, Object>{
        'recording': recording,
      });

  Future<void> showArticle({
    required Uri uri,
    String? query,
    required int x,
    required int y,
  }) =>
      _channel.invokeMethod<void>('showArticle', <String, Object>{
        'uri': uri.toString(),
        if (query != null) 'query': query,
        'x': x,
        'y': y,
      });

  Future<void> showMessage({
    required String title,
    required String message,
    required int x,
    required int y,
  }) =>
      _channel.invokeMethod<void>('showMessage', <String, Object>{
        'title': title,
        'message': message,
        'x': x,
        'y': y,
      });

  Future<void> hide() => _channel.invokeMethod<void>('hide');

  Future<String> loadAiApiKey() async =>
      await _channel.invokeMethod<String>(
        'loadAiApiKey',
        const <String, Object>{},
      ) ??
      '';

  Future<void> saveAiApiKey(String apiKey) =>
      _channel.invokeMethod<void>('saveAiApiKey', <String, Object>{
        'apiKey': apiKey,
      });

  Future<void> deleteAiApiKey() => _channel.invokeMethod<void>(
        'deleteAiApiKey',
        const <String, Object>{},
      );

  Future<void> updateAiResult(
    String payload, {
    required bool pending,
  }) =>
      _channel.invokeMethod<void>('updateAiResult', <String, Object>{
        'payload': payload,
        'pending': pending,
      });
}

/// Reuses the established event contract without changing Windows channel IDs.
class DesktopScreenLookup extends WindowsScreenLookup {
  DesktopScreenLookup()
      : super(
            channel: MethodChannel(Platform.isMacOS
                ? 'local_dictionary/macos_screen_lookup'
                : 'local_dictionary/windows_screen_lookup'));

  static const _macos = MethodChannel('local_dictionary/macos_screen_lookup');
  Future<bool> hasAccessibilityPermission() async =>
      !Platform.isMacOS ||
      await _macos.invokeMethod<bool>('hasAccessibilityPermission') == true;
  Future<void> showCurrentApplication() =>
      _macos.invokeMethod<void>('showCurrentApplication');
  Future<void> openAccessibilitySettings() =>
      _macos.invokeMethod<void>('openAccessibilitySettings');
}
