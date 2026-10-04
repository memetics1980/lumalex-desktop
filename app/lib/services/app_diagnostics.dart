import 'dart:io';

import 'package:flutter/services.dart';

import 'reader_diagnostics.dart';

class AndroidRuntimeDiagnostics {
  const AndroidRuntimeDiagnostics({
    required this.versionName,
    required this.versionCode,
    required this.sdkInt,
    required this.device,
    required this.supportedAbis,
    required this.webViewVersion,
    required this.memoryClassMb,
    required this.isLowRamDevice,
    required this.stagedDictionaryBytes,
    required this.indexBytes,
  });

  factory AndroidRuntimeDiagnostics.fromMap(Map<Object?, Object?> value) {
    int integer(String key) => (value[key] as num?)?.toInt() ?? 0;
    return AndroidRuntimeDiagnostics(
      versionName: value['versionName'] as String? ?? 'unknown',
      versionCode: value['versionCode'] as String? ?? 'unknown',
      sdkInt: integer('sdkInt'),
      device: value['device'] as String? ?? 'unknown',
      supportedAbis: (value['supportedAbis'] as List<Object?>?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const [],
      webViewVersion: value['webViewVersion'] as String? ?? 'unknown',
      memoryClassMb: integer('memoryClassMb'),
      isLowRamDevice: value['isLowRamDevice'] as bool? ?? false,
      stagedDictionaryBytes: integer('stagedDictionaryBytes'),
      indexBytes: integer('indexBytes'),
    );
  }

  final String versionName;
  final String versionCode;
  final int sdkInt;
  final String device;
  final List<String> supportedAbis;
  final String webViewVersion;
  final int memoryClassMb;
  final bool isLowRamDevice;
  final int stagedDictionaryBytes;
  final int indexBytes;
}

class AppDiagnosticsReport {
  const AppDiagnosticsReport({
    required this.generatedAt,
    required this.runtime,
    required this.dictionaryCount,
    required this.enabledDictionaryCount,
    required this.availableDictionaryCount,
    required this.historyCount,
    required this.favoriteCount,
    required this.reviewCardCount,
    required this.readerEvents,
  });

  final DateTime generatedAt;
  final AndroidRuntimeDiagnostics runtime;
  final int dictionaryCount;
  final int enabledDictionaryCount;
  final int availableDictionaryCount;
  final int historyCount;
  final int favoriteCount;
  final int reviewCardCount;
  final List<String> readerEvents;

  String toText() => [
        'LumaLex Android diagnostics',
        'Generated: ${generatedAt.toUtc().toIso8601String()}',
        'App: ${runtime.versionName} (${runtime.versionCode})',
        'Device: ${runtime.device}',
        'Android SDK: ${runtime.sdkInt}',
        'ABIs: ${runtime.supportedAbis.join(', ')}',
        'Android System WebView: ${runtime.webViewVersion}',
        'Memory class: ${runtime.memoryClassMb} MB',
        'Low-RAM device: ${runtime.isLowRamDevice}',
        'Dictionaries: $availableDictionaryCount available / '
            '$enabledDictionaryCount enabled / $dictionaryCount managed',
        'Staged MDX data: ${formatByteCount(runtime.stagedDictionaryBytes)}',
        'Persistent indexes: ${formatByteCount(runtime.indexBytes)}',
        'Word records: $historyCount history / $favoriteCount favorites / '
            '$reviewCardCount review cards',
        '',
        'Reader events (${readerEvents.length})',
        if (readerEvents.isEmpty) '(none)' else ...readerEvents,
        '',
      ].join('\n');
}

String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(1)} MiB';
  return '${(mib / 1024).toStringAsFixed(2)} GiB';
}

class AppDiagnosticsService {
  AppDiagnosticsService({
    MethodChannel? channel,
    ReaderDiagnostics? readerDiagnostics,
  })  : _channel =
            channel ?? const MethodChannel('local_dictionary/app_diagnostics'),
        _readerDiagnostics = readerDiagnostics ?? ReaderDiagnostics.instance;

  final MethodChannel _channel;
  final ReaderDiagnostics _readerDiagnostics;

  Future<AppDiagnosticsReport> collect({
    required int dictionaryCount,
    required int enabledDictionaryCount,
    required int availableDictionaryCount,
    required int historyCount,
    required int favoriteCount,
    required int reviewCardCount,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android runtime diagnostics are unavailable.');
    }
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'getRuntimeDiagnostics',
    );
    if (raw == null) {
      throw const FormatException('Android returned no runtime diagnostics.');
    }
    final events = await _readerDiagnostics.readLines();
    return AppDiagnosticsReport(
      generatedAt: DateTime.now(),
      runtime: AndroidRuntimeDiagnostics.fromMap(raw),
      dictionaryCount: dictionaryCount,
      enabledDictionaryCount: enabledDictionaryCount,
      availableDictionaryCount: availableDictionaryCount,
      historyCount: historyCount,
      favoriteCount: favoriteCount,
      reviewCardCount: reviewCardCount,
      readerEvents: events,
    );
  }

  Future<void> clearReaderEvents() => _readerDiagnostics.clear();
}
