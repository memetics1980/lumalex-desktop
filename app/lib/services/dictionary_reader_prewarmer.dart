import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Pays Android WebView's process-startup cost before the first lookup.
///
/// The visible dictionary reader still owns its long-lived WebView. This
/// short-lived headless page starts Chromium at a quiet point after app launch,
/// then releases the page without transferring its creation-time settings.
final class DictionaryReaderPrewarmer {
  DictionaryReaderPrewarmer._();

  static final DictionaryReaderPrewarmer instance =
      DictionaryReaderPrewarmer._();

  Future<void>? _prewarmFuture;
  HeadlessInAppWebView? _headlessWebView;

  Future<void> prewarm() {
    if (!Platform.isAndroid) {
      return Future.value();
    }
    return _prewarmFuture ??= _runBestEffort();
  }

  Future<void> disposeUnused() async {
    final webView = _headlessWebView;
    _headlessWebView = null;
    if (webView != null && webView.isRunning()) {
      await webView.dispose().catchError((Object _) {});
    }
  }

  Future<void> _runBestEffort() async {
    final ready = Completer<void>();
    late final HeadlessInAppWebView headlessWebView;
    void markReady() {
      if (!ready.isCompleted) {
        ready.complete();
      }
    }

    headlessWebView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: '<!doctype html><meta charset="utf-8"><body></body>',
      ),
      initialSettings: InAppWebViewSettings(
        cacheEnabled: true,
        javaScriptEnabled: true,
        supportMultipleWindows: false,
      ),
      onPageCommitVisible: (_, __) => markReady(),
      onLoadStop: (_, __) => markReady(),
    );
    _headlessWebView = headlessWebView;

    final timer = Stopwatch()..start();
    try {
      await headlessWebView.run();
      await ready.future.timeout(const Duration(seconds: 4));
      debugPrint(
        'Dictionary WebView prewarmed: totalMs=${timer.elapsedMilliseconds}',
      );
    } catch (error) {
      // Warmup is an optimization only. The visible reader remains capable of
      // starting Chromium normally if a device WebView rejects headless mode.
      debugPrint('Dictionary WebView warmup skipped: $error');
      if (identical(_headlessWebView, headlessWebView)) {
        _headlessWebView = null;
      }
    } finally {
      // Warming the Chromium process is safe; transferring the headless view
      // is not. flutter_inappwebview reuses its creation-time settings during
      // that transfer, which would drop the reader's mobile viewport, custom
      // context menu, and security settings. The real reader therefore always
      // creates a correctly configured WebView after this process warm-up.
      if (identical(_headlessWebView, headlessWebView)) {
        _headlessWebView = null;
      }
      if (headlessWebView.isRunning()) {
        await headlessWebView.dispose().catchError((Object _) {});
      }
    }
  }
}
