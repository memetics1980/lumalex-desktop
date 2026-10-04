import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/app_diagnostics.dart';

void main() {
  test('byte counts use compact readable units', () {
    expect(formatByteCount(12), '12 B');
    expect(formatByteCount(1536), '1.5 KiB');
    expect(formatByteCount(5 * 1024 * 1024), '5.0 MiB');
  });

  test('diagnostic report contains runtime and local-only state', () {
    final report = AppDiagnosticsReport(
      generatedAt: DateTime.utc(2026, 9, 18),
      runtime: const AndroidRuntimeDiagnostics(
        versionName: '0.1.0',
        versionCode: '43',
        sdkInt: 36,
        device: 'Example Phone',
        supportedAbis: ['arm64-v8a'],
        webViewVersion: '153.0',
        memoryClassMb: 256,
        isLowRamDevice: false,
        stagedDictionaryBytes: 1024,
        indexBytes: 2048,
      ),
      dictionaryCount: 3,
      enabledDictionaryCount: 2,
      availableDictionaryCount: 2,
      historyCount: 12,
      favoriteCount: 4,
      reviewCardCount: 4,
      readerEvents: const ['{"event":"recovered"}'],
    );

    final text = report.toText();
    expect(text, contains('App: 0.1.0 (43)'));
    expect(text, contains('2 available / 2 enabled / 3 managed'));
    expect(text, contains('Reader events (1)'));
  });
}
