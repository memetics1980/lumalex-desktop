import 'dart:async';

import 'package:flutter/services.dart';

enum WindowsScreenLookupShortcut {
  ctrlAltL('Ctrl + Alt + L'),
  ctrlShiftL('Ctrl + Shift + L'),
  altQ('Alt + Q');

  const WindowsScreenLookupShortcut(this.label);

  final String label;
}

WindowsScreenLookupShortcut windowsScreenLookupShortcutFromStorage(
  String? value,
) =>
    WindowsScreenLookupShortcut.values.firstWhere(
      (shortcut) => shortcut.name == value,
      orElse: () => WindowsScreenLookupShortcut.ctrlAltL,
    );

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

  Future<void> showArticle({
    required Uri uri,
    required int x,
    required int y,
  }) =>
      _channel.invokeMethod<void>('showArticle', <String, Object>{
        'uri': uri.toString(),
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
