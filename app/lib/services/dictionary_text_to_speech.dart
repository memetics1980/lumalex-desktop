import 'dart:io';

import 'package:flutter/services.dart';

bool supportsDictionaryTextToSpeechOn(String operatingSystem) =>
    switch (operatingSystem.toLowerCase()) {
      'android' || 'ios' || 'windows' => true,
      _ => false,
    };

/// Small platform bridge for dictionary entries that provide text-to-speech
/// controls instead of a sound file in an MDD volume.
class DictionaryTextToSpeech {
  static const _channel = MethodChannel('local_dictionary/text_to_speech');

  Future<void> speak(String text, {required String locale}) async {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty || normalized.length > 2000) {
      throw const FormatException('The example text is not valid for speech.');
    }
    if (!supportsDictionaryTextToSpeechOn(Platform.operatingSystem)) {
      throw UnsupportedError('System text-to-speech is not available here.');
    }
    final started = await _channel.invokeMethod<bool>(
      'speak',
      <String, Object>{'text': normalized, 'locale': locale},
    );
    if (started != true) {
      throw StateError('The system text-to-speech service did not start.');
    }
  }

  Future<void> stop() async {
    if (!supportsDictionaryTextToSpeechOn(Platform.operatingSystem)) return;
    await _channel.invokeMethod<void>('stop');
  }
}
