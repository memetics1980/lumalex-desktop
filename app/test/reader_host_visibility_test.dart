import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_dictionary/platform/reader_host_visibility.dart';

void main() {
  test('hidden host is remembered before WebView creation', () async {
    final writes = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.setVisible(false);
    await visibility.bind((value) async => writes.add(value));
    expect(writes, [false]);
  });

  test('repeated states do not pause or resume again', () async {
    final writes = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.bind((value) async => writes.add(value));
    await visibility.setVisible(false);
    await visibility.setVisible(false);
    await visibility.setVisible(true);
    await visibility.setVisible(true);
    expect(writes, [true, false, true]);
  });

  test('restore waits for an already running pause', () async {
    final pauseStarted = Completer<void>();
    final releasePause = Completer<void>();
    final writes = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.bind((value) async {
      writes.add(value);
      if (!value) {
        pauseStarted.complete();
        await releasePause.future;
      }
    });
    final hide = visibility.setVisible(false);
    await pauseStarted.future;
    final show = visibility.setVisible(true);
    expect(writes, [true, false]);
    releasePause.complete();
    await Future.wait([hide, show]);
    expect(writes, [true, false, true]);
  });

  test('queued changes use newest state rather than stale commands', () async {
    final writes = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.bind((value) async => writes.add(value));
    await Future.wait([
      visibility.setVisible(false),
      visibility.setVisible(true),
    ]);
    expect(writes, [true]);
  });

  test('replacement reader gets current visibility after old pause', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final oldWrites = <bool>[];
    final newWrites = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.bind((value) async {
      oldWrites.add(value);
      if (!value) {
        started.complete();
        await release.future;
      }
    });
    final hide = visibility.setVisible(false);
    await started.future;
    final bind = visibility.bind((value) async => newWrites.add(value));
    release.complete();
    await Future.wait([hide, bind]);
    expect(oldWrites, [true, false]);
    expect(newWrites, [false]);
  });

  test('detached reader is not called by later requests', () async {
    final writes = <bool>[];
    final visibility = ReaderHostVisibility(onError: failError);
    await visibility.bind((value) async => writes.add(value));
    await visibility.bind(null);
    await visibility.setVisible(false);
    expect(writes, [true]);
  });

  test('failed visibility update is reported and can be retried', () async {
    final errors = <Object>[];
    var attempts = 0;
    final visibility = ReaderHostVisibility(onError: errors.add);
    await visibility.bind((value) async {
      if (++attempts == 1) throw StateError('closed controller');
    });
    await visibility.setVisible(true);
    expect(errors, hasLength(1));
    expect(attempts, 2);
  });
}

void failError(Object error) => fail('Unexpected visibility error: $error');
