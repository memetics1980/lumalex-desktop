import 'dart:io';

import 'package:flutter/services.dart';

final class AndroidReaderMemoryProfile {
  const AndroidReaderMemoryProfile({
    required this.memoryClassMb,
    required this.isLowRamDevice,
  });

  final int memoryClassMb;
  final bool isLowRamDevice;

  static AndroidReaderMemoryProfile? fromPlatformValue(Object? value) {
    if (value is! Map) return null;
    final memoryClassMb = value['memoryClassMb'];
    final isLowRamDevice = value['isLowRamDevice'];
    if (memoryClassMb is! int || isLowRamDevice is! bool) return null;
    return AndroidReaderMemoryProfile(
      memoryClassMb: memoryClassMb,
      isLowRamDevice: isLowRamDevice,
    );
  }
}

final class AndroidReaderMemory {
  AndroidReaderMemory._();

  static const _channel = MethodChannel('local_dictionary/reader_memory');

  static Future<AndroidReaderMemoryProfile?> readProfile() async {
    if (!Platform.isAndroid) return null;
    try {
      final value = await _channel.invokeMethod<Object?>('getMemoryProfile');
      return AndroidReaderMemoryProfile.fromPlatformValue(value);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
