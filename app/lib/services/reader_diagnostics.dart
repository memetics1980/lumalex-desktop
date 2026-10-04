import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _maximumReaderDiagnosticLines = 200;

List<String> trimReaderDiagnosticLinesForTesting(
  Iterable<String> lines, {
  int maximumLines = _maximumReaderDiagnosticLines,
}) {
  if (maximumLines <= 0) return const [];
  final values = lines.toList(growable: false);
  if (values.length <= maximumLines) return values;
  return values.sublist(values.length - maximumLines);
}

/// Keeps a small, local-only record of reader lifecycle failures and recovery.
///
/// The log never leaves the device. Writes are serialized and the file retains
/// only the latest events so diagnostics cannot grow without bound.
final class ReaderDiagnostics {
  ReaderDiagnostics._();

  static final ReaderDiagnostics instance = ReaderDiagnostics._();

  Future<void> _writeTail = Future.value();

  void record(String event, {Map<String, Object?> data = const {}}) {
    final line = jsonEncode({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      if (data.isNotEmpty) 'data': data,
    });
    final previous = _writeTail;
    _writeTail = () async {
      try {
        await previous;
      } catch (_) {
        // A later event should still be writable after an earlier I/O failure.
      }
      try {
        await _writeLine(line);
      } catch (error) {
        debugPrint('Reader diagnostic log write failed: $error');
      }
    }();
  }

  Future<String> logPath() async => (await _logFile()).path;

  Future<List<String>> readLines() async {
    try {
      await _writeTail;
    } catch (_) {
      // A failed pending write must not make existing diagnostics unreadable.
    }
    final file = await _logFile();
    if (!await file.exists()) return const [];
    return trimReaderDiagnosticLinesForTesting(await file.readAsLines());
  }

  Future<void> clear() async {
    try {
      await _writeTail;
    } catch (_) {
      // Clearing remains useful after a failed pending write.
    }
    final file = await _logFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _logFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
        '${directory.path}${Platform.pathSeparator}reader-events.jsonl');
  }

  Future<void> _writeLine(String line) async {
    final file = await _logFile();
    final existing =
        await file.exists() ? await file.readAsLines() : <String>[];
    final retained = trimReaderDiagnosticLinesForTesting([
      ...existing,
      line,
    ]);
    await file.writeAsString('${retained.join('\n')}\n', flush: true);
  }
}
