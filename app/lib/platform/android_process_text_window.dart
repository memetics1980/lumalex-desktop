import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge for the Android-only floating PROCESS_TEXT lookup window.
///
/// The regular launcher activity never calls this bridge. Keeping movement
/// and sizing native avoids requesting the system overlay permission.
abstract final class AndroidProcessTextWindow {
  static const _channel = MethodChannel(
    'local_dictionary/process_text_window',
  );

  static Future<String> selectedText() async {
    try {
      return (await _channel
                  .invokeMethod<String>('getSelectedText')
                  .timeout(const Duration(seconds: 2)))
              ?.trim() ??
          '';
    } on Object {
      return '';
    }
  }

  static Future<void> toggleMaximized() async {
    try {
      await _channel.invokeMethod<void>('toggleMaximized');
    } on Object {
      // A window affordance must never make dictionary lookup fail.
    }
  }

  static Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on Object {
      await SystemNavigator.pop();
    }
  }
}
