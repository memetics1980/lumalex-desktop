import 'dart:async';

import 'package:flutter/services.dart';

import '../services/windows_app_settings.dart';

typedef WindowsWindowLifecycleEventHandler = FutureOr<void> Function(
  String event,
);

class WindowsWindowLifecycle {
  WindowsWindowLifecycle({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('local_dictionary/windows_window_lifecycle');

  final MethodChannel _channel;

  void attach(WindowsWindowLifecycleEventHandler handler) =>
      _channel.setMethodCallHandler((call) async {
        await handler(call.method);
      });

  void detach() => _channel.setMethodCallHandler(null);

  Future<void> configure({
    required WindowsCloseBehavior closeBehavior,
    required bool showFirstHideNotification,
  }) =>
      _channel.invokeMethod<void>('setCloseBehavior', <String, Object>{
        'behavior': closeBehavior == WindowsCloseBehavior.hideToTray
            ? 'hideToTray'
            : 'exit',
        'showFirstHideNotification': showFirstHideNotification,
      });
}
