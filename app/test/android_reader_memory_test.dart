import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/platform/android_reader_memory.dart';

void main() {
  test('parses Android ActivityManager memory profile', () {
    final profile = AndroidReaderMemoryProfile.fromPlatformValue({
      'memoryClassMb': 512,
      'isLowRamDevice': false,
    });

    expect(profile?.memoryClassMb, 512);
    expect(profile?.isLowRamDevice, isFalse);
  });

  test('rejects incomplete Android memory profiles', () {
    expect(
      AndroidReaderMemoryProfile.fromPlatformValue({
        'memoryClassMb': '512',
        'isLowRamDevice': false,
      }),
      isNull,
    );
    expect(AndroidReaderMemoryProfile.fromPlatformValue(null), isNull);
  });
}
