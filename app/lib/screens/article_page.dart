import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:just_audio/just_audio.dart';

import '../models/article.dart';
import '../platform/reader_platform_policy.dart';
import '../services/dictionary_content_server.dart';
import '../services/dictionary_engine.dart';
import '../services/dictionary_text_to_speech.dart';
import '../services/reader_diagnostics.dart';

const _maxResourceBytes = 20 * 1024 * 1024;
const _soundHandlerName = 'playDictionarySound';
const _textToSpeechHandlerName = 'speakDictionaryExample';
const _wordLookupHandlerName = 'lookupDictionaryWord';
const _documentHeightHandlerName = 'dictionaryDocumentHeightChanged';
const _readingScrollHandlerName = 'dictionaryReaderDidScroll';
const _selectionChangeHandlerName = 'dictionaryReaderSelectionChanged';
const _selectionActionHandlerName = 'dictionaryReaderSelectionAction';
const windowsSelectionMenuRequestedHandlerName =
    'dictionaryWindowsSelectionMenuRequested';
const _windowsSelectionLookupScheme = 'lumalex-selection';
const _windowsSelectionLookupPath = '/__lumalex_selection_lookup__';
const _copySelectionContextMenuItemId = 1000;
const _lookupSelectionContextMenuItemId = 1001;
const _windowsAudioLoadStabilizationDelay = Duration(milliseconds: 80);

typedef WindowsSelectionLookupRequest = ({String text, String? token});

enum _WindowsSelectionMenuAction { copy, lookup }

@visibleForTesting
WindowsSelectionLookupRequest? windowsSelectionLookupRequestForTesting(
  String? rawUrl,
) {
  final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
  if (uri == null) return null;
  final isCustomScheme =
      uri.scheme.toLowerCase() == _windowsSelectionLookupScheme &&
          uri.host.toLowerCase() == 'lookup';
  final isLoopbackRoute = (uri.scheme == 'http' || uri.scheme == 'https') &&
      (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
      uri.path == _windowsSelectionLookupPath;
  if (!isCustomScheme && !isLoopbackRoute) {
    return null;
  }
  final text = uri.queryParameters['text']?.trim();
  if (text == null || text.isEmpty) return null;
  final rawToken = uri.queryParameters['token']?.trim();
  return (text: text, token: rawToken?.isEmpty ?? true ? null : rawToken);
}

final class WebContentRecoveryLimiter {
  WebContentRecoveryLimiter({
    this.maximumAutomaticRecoveries = 2,
    this.window = const Duration(seconds: 30),
  });

  final int maximumAutomaticRecoveries;
  final Duration window;
  final List<DateTime> _terminations = [];

  int get recentTerminationCount => _terminations.length;

  bool registerTermination(DateTime timestamp) {
    _terminations.removeWhere(
      (value) => timestamp.difference(value) >= window,
    );
    _terminations.add(timestamp);
    return _terminations.length <= maximumAutomaticRecoveries;
  }

  void reset() => _terminations.clear();
}

class ArticlePageController {
  _ArticlePageState? _state;

  double get lastKnownScrollOffset => _state?._lastKnownScrollOffset ?? 0;

  Future<double> readScrollOffset() async =>
      await _state?._readScrollOffset() ?? 0;

  Future<void> recoverAfterForeground({bool forceReload = false}) async =>
      _state?._recoverAfterForeground(forceReload: forceReload);

  Future<void> releaseTransientResources() async =>
      _state?._releaseTransientResources();

  Future<void> stopPlayback() async => _state?._stopPlayback();

  void _attach(_ArticlePageState state) => _state = state;

  void _detach(_ArticlePageState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

/// Displays an MDX article as an isolated local web application.
///
/// Dictionary-authored HTML, CSS and JavaScript share a loopback-only origin,
/// while external network navigation, file access, forms and frames remain
/// unavailable.
class ArticlePage extends StatefulWidget {
  const ArticlePage({
    required this.article,
    required this.engine,
    required this.localScriptCompatibilityEnabled,
    this.initialAnchor,
    this.initialScrollOffset,
    this.embedded = false,
    this.interactionEnabled = true,
    this.onInteractionShieldTap,
    this.onOpenHeadword,
    this.controller,
    this.textScale = 1,
    this.fitDocumentHeight = false,
    this.onDocumentHeightChanged,
    this.onReadingScroll,
    this.onDocumentRendered,
    super.key,
  });

  final Article article;
  final DictionaryEngine engine;
  final bool localScriptCompatibilityEnabled;
  final String? initialAnchor;
  final double? initialScrollOffset;
  final bool embedded;
  final bool interactionEnabled;
  final VoidCallback? onInteractionShieldTap;
  final Future<void> Function(
    String headword,
    String? anchor,
    double sourceScrollOffset,
  )? onOpenHeadword;
  final ArticlePageController? controller;
  final double textScale;
  final bool fitDocumentHeight;
  final ValueChanged<double>? onDocumentHeightChanged;
  final VoidCallback? onReadingScroll;
  final VoidCallback? onDocumentRendered;

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage>
    with AutomaticKeepAliveClientMixin<ArticlePage> {
  late final _readerPlatformPolicy = ReaderPlatformPolicy.current;
  late final InAppWebViewKeepAlive? _webViewKeepAlive =
      _readerPlatformPolicy.keepArticlePlatformViewAlive
          ? InAppWebViewKeepAlive()
          : null;
  InAppWebViewController? _webViewController;
  DictionaryContentSession? _contentSession;
  AudioPlayer? _audioPlayer;
  final _textToSpeech = DictionaryTextToSpeech();
  Directory? _activeAudioDirectory;
  Timer? _loadTimeout;
  bool _showFallback = false;
  bool _isPageLoading = true;
  bool _hasRenderedDocument = false;
  bool _isFollowingLink = false;
  int _documentLoadGeneration = 0;
  int _visibleDocumentGeneration = -1;
  int? _documentLoadStartedMicroseconds;
  int? _webViewNavigationStartedMicroseconds;
  int _audioRequestGeneration = 0;
  Future<void>? _contentRecovery;
  double? _pendingRecoveryScrollOffset;
  double _lastKnownScrollOffset = 0;
  String? _lastSelectedText;
  String? _lastSelectedHeadword;
  Rect? _lastSelectionRect;
  Size? _lastSelectionViewport;
  bool _isSelectionLookup = false;
  bool _isShowingWindowsSelectionMenu = false;
  final _readerSurfaceKey = GlobalKey();
  String? _lastAudioResourcePath;
  int _lastAudioRequestMilliseconds = 0;
  String _fallbackReason = '词条页面加载超时。';
  late final ContextMenu _selectionContextMenu;
  final _webContentRecoveryLimiter = WebContentRecoveryLimiter();

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _selectionContextMenu = ContextMenu(
      // Android otherwise injects a device-dependent list of browser and
      // installed-app actions. Dictionary reading needs only these two.
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      menuItems: [
        ContextMenuItem(
          id: _copySelectionContextMenuItemId,
          title: '复制',
          action: _copySelectedTextFromContextMenu,
        ),
        ContextMenuItem(
          id: _lookupSelectionContextMenuItemId,
          title: '查词',
          action: _lookupSelectedTextFromContextMenu,
        ),
      ],
      onCreateContextMenu: (_) => _refreshSelectedTextFromWebView(),
    );
    _armLoadTimeout();
  }

  void _armLoadTimeout() {
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted) {
        setState(() {
          _isPageLoading = false;
          _showFallback = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _documentLoadGeneration++;
    _audioRequestGeneration++;
    widget.controller?._detach(this);
    _loadTimeout?.cancel();
    _contentSession?.close();
    final webViewKeepAlive = _webViewKeepAlive;
    if (webViewKeepAlive != null) {
      unawaited(InAppWebViewController.disposeKeepAlive(webViewKeepAlive));
    }
    final player = _audioPlayer;
    if (player != null) {
      unawaited(player.dispose());
    }
    unawaited(_textToSpeech.stop());
    unawaited(_removeActiveAudioCache());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ArticlePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (widget.textScale != oldWidget.textScale) {
      final controller = _webViewController;
      if (controller != null) {
        unawaited(_applyTextScale(controller));
      }
    }
    final documentChanged =
        widget.article.mdxPath != oldWidget.article.mdxPath ||
            widget.article.headword != oldWidget.article.headword ||
            widget.article.html != oldWidget.article.html;
    if (documentChanged) {
      _webContentRecoveryLimiter.reset();
      final controller = _webViewController;
      if (controller != null) {
        // A stable iOS reader slot replaces its document without disposing the
        // WKWebView. Explicitly release media and selection state that disposal
        // used to clean up before loading the newly assigned dictionary.
        unawaited(_releaseTransientResources());
        unawaited(_loadArticleDocument(controller));
      }
      return;
    }

    // An anchor or saved scroll offset is a one-time navigation request, not
    // part of an article's identity. A retained reader becomes unselected
    // with null values and receives its original request again when selected
    // later; treating that prop change as a new document needlessly reloads
    // the same entry.
    if (widget.initialAnchor != oldWidget.initialAnchor ||
        widget.initialScrollOffset != oldWidget.initialScrollOffset) {
      final controller = _webViewController;
      if (controller != null && _hasRenderedDocument) {
        unawaited(_applyRequestedPosition(controller));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final showIosSelectionToolbar = Platform.isIOS &&
        _lastSelectedText != null &&
        _lastSelectionRect != null &&
        _lastSelectionViewport != null;
    final articleBody = Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          key: _readerSurfaceKey,
          ignoring: !widget.interactionEnabled,
          child: InAppWebView(
            // The reader is deliberately one long-lived WebView. Changing the
            // selected dictionary swaps its local document in didUpdateWidget
            // instead of tearing down Chromium and its resource cache.
            key: const ValueKey('lumalex-article-webview'),
            keepAlive: _webViewKeepAlive,
            initialSettings: InAppWebViewSettings(
              allowContentAccess: false,
              allowFileAccess: false,
              // The only permitted origin is a server bound to 127.0.0.1. The
              // document CSP rejects all non-local resources.
              blockNetworkLoads: false,
              // Dictionary sessions use a fresh URL on every lookup. WebKit
              // cannot reuse an old response, so keeping those one-off
              // resources only increases iOS memory pressure.
              cacheEnabled: !Platform.isIOS,
              // iOS uses a Flutter-owned selection toolbar. Keeping WebKit's
              // edit menu disabled prevents duplicate system actions and also
              // avoids the plugin's unsafe custom-selector implementation.
              // Windows uses a Flutter-owned Copy/Lookup popup above WebView2.
              // Keep Chromium's menu disabled so the two menus never overlap.
              disableContextMenu: Platform.isIOS || Platform.isWindows,
              disableVerticalScroll: widget.fitDocumentHeight,
              incognito: false,
              javaScriptCanOpenWindowsAutomatically: false,
              javaScriptEnabled: true,
              // Dictionary text size is owned by LumaLex's explicit Aa
              // control. Android WebView's layout/text zoom must stay fixed
              // while the PROCESS_TEXT window is resized continuously.
              builtInZoomControls: false,
              displayZoomControls: false,
              layoutAlgorithm: LayoutAlgorithm.NORMAL,
              mediaPlaybackRequiresUserGesture: true,
              resourceCustomSchemes: const ['dictres', 'sound'],
              supportZoom: false,
              supportMultipleWindows: false,
              textZoom: 100,
              useShouldOverrideUrlLoading: true,
              // Match the mobile viewport behavior used by dedicated
              // dictionary readers. Publisher CSS then lays out against the
              // actual phone width rather than Chromium's desktop viewport.
              useWideViewPort: false,
            ),
            // flutter_inappwebview's iOS custom-menu implementation swizzles
            // UIKit selectors at runtime. On iPad that path can abort in
            // os_unfair_lock_corruption_abort when a custom item is invoked.
            // On iOS the document reports selection text and coordinates, and
            // Flutter draws the Copy/Lookup toolbar beside that selection.
            contextMenu: Platform.isIOS || Platform.isWindows
                ? null
                : _selectionContextMenu,
            shouldOverrideUrlLoading: (controller, action) =>
                _handleNavigation(controller, action.request.url?.rawValue),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              if (!Platform.isIOS && !Platform.isWindows) {
                // Android otherwise injects a device-dependent list of
                // browser and installed-app actions.
                unawaited(controller.setContextMenu(_selectionContextMenu));
              }
              controller.addJavaScriptHandler(
                handlerName: _soundHandlerName,
                callback: (arguments) {
                  final rawUri = arguments.firstOrNull;
                  final uri = rawUri is String ? Uri.tryParse(rawUri) : null;
                  if (uri?.scheme.toLowerCase() == 'sound') {
                    unawaited(_playSound(uri!));
                  }
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _textToSpeechHandlerName,
                callback: (arguments) {
                  final text = arguments.firstOrNull;
                  final locale = arguments.elementAtOrNull(1);
                  if (text is String && locale is String) {
                    unawaited(_speakExample(text, locale));
                  }
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _wordLookupHandlerName,
                callback: (arguments) {
                  final headword = doubleClickLookupHeadwordForTesting(
                    arguments.firstOrNull,
                  );
                  if (headword != null) {
                    unawaited(
                      _followDictionaryLink(
                        controller,
                        (headword: headword, anchor: null),
                      ),
                    );
                  }
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _documentHeightHandlerName,
                callback: (arguments) {
                  final height = arguments.firstOrNull;
                  if (widget.fitDocumentHeight &&
                      height is num &&
                      height.isFinite &&
                      height > 0) {
                    widget.onDocumentHeightChanged?.call(height.toDouble());
                  }
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _readingScrollHandlerName,
                callback: (arguments) {
                  final offset = arguments.firstOrNull;
                  if (offset is num && offset.isFinite && offset >= 0) {
                    _lastKnownScrollOffset = offset.toDouble();
                  }
                  widget.onReadingScroll?.call();
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _selectionChangeHandlerName,
                callback: (arguments) {
                  final selection = dictionarySelectionForTesting(arguments);
                  final text = selection?.text;
                  final headword = selection?.headword;
                  final rect = selection?.rect;
                  final viewport = selection?.viewport;
                  if (_lastSelectedText == text &&
                      _lastSelectedHeadword == headword &&
                      _lastSelectionRect == rect &&
                      _lastSelectionViewport == viewport) {
                    return null;
                  }
                  _lastSelectedText = text;
                  _lastSelectedHeadword = headword;
                  _lastSelectionRect = rect;
                  _lastSelectionViewport = viewport;
                  if (Platform.isIOS && mounted) {
                    setState(() {});
                  }
                  return null;
                },
              );
              controller.addJavaScriptHandler(
                handlerName: _selectionActionHandlerName,
                // Return the Future to WebView2 so the document-side menu can
                // wait until Flutter has accepted the first action before it
                // removes itself.
                callback: _handleWindowsSelectionAction,
              );
              controller.addJavaScriptHandler(
                handlerName: windowsSelectionMenuRequestedHandlerName,
                callback: _handleWindowsSelectionMenuRequest,
              );
              debugPrint('Dictionary WebView created');
              // flutter_inappwebview invokes this callback again when an
              // Android keep-alive WebView is attached to a fresh platform
              // surface. The native page is already loaded in that case.
              if (_contentSession == null) {
                unawaited(_loadArticleDocument(controller));
              } else {
                debugPrint(
                  'Dictionary WebView reattached without reload: '
                  '${widget.article.headword}',
                );
              }
            },
            onLoadStart: _handleLoadStart,
            onPageCommitVisible: _handlePageCommitVisible,
            onLoadStop: _handleLoadStop,
            onReceivedError: (_, request, error) {
              debugPrint(
                'Dictionary WebView error for ${request.url.rawValue}: $error',
              );
              if (_isExpectedNavigationCancellation(request, error)) {
                return;
              }
              if (request.isForMainFrame == true && mounted) {
                _loadTimeout?.cancel();
                setState(() {
                  _isPageLoading = false;
                  _fallbackReason = '富文本页面加载失败：$error';
                  _showFallback = true;
                });
              }
            },
            onWebContentProcessDidTerminate:
                _handleWebContentProcessTermination,
            onLoadResourceWithCustomScheme: (_, request) =>
                _loadCustomSchemeResource(request.url.uriValue),
          ),
        ),
        if (!widget.interactionEnabled)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onInteractionShieldTap,
              child: const ColoredBox(color: Color(0x08000000)),
            ),
          ),
        if (_showFallback) _buildFallback(context),
        if (_isPageLoading && !_hasRenderedDocument)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: const Center(child: CircularProgressIndicator()),
          ),
        if (_isFollowingLink || (_isPageLoading && _hasRenderedDocument))
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (showIosSelectionToolbar) _buildIosSelectionToolbar(context),
      ],
    );
    if (widget.embedded) {
      return articleBody;
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.article.headword)),
      body: SafeArea(child: articleBody),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final uri = url?.uriValue;
    if (uri != null && !(_contentSession?.owns(uri) ?? false)) {
      return;
    }
    final generation = _documentLoadGeneration;
    if (!_readerPlatformPolicy.revealArticleAfterSetup) {
      // Preserve WebKit's established display timing. Its platform-specific
      // memory recovery runs separately after foreground transitions.
      _markDocumentVisible(url, phase: 'load-stop');
      await _finishDocumentSetup(controller, url, generation);
      return;
    }
    await _finishDocumentSetup(controller, url, generation);
    if (!mounted || generation != _documentLoadGeneration) {
      return;
    }
    // A commit-visible callback can arrive while Chromium is still parsing
    // the entry. In particular, a non-default reader size is applied after
    // the publisher CSS has loaded. Revealing the document at commit time
    // makes that final size adjustment look like a zoom animation.
    _markDocumentVisible(url, phase: 'load-stop-after-setup');
  }

  void _handlePageCommitVisible(
    InAppWebViewController controller,
    WebUri? url,
  ) {
    final uri = url?.uriValue;
    if (uri != null && !(_contentSession?.owns(uri) ?? false)) {
      return;
    }
    if (!_readerPlatformPolicy.revealArticleAfterSetup) {
      _markDocumentVisible(url, phase: 'commit-visible');
      return;
    }
    // Keep the loading cover in place until _handleLoadStop has applied the
    // requested text scale and the reader bridges. See _handleLoadStop.
    debugPrint(
      'Dictionary WebView committed: headword=${widget.article.headword}; '
      'url=${url?.rawValue}; '
      'renderMs=${_elapsedMilliseconds(_webViewNavigationStartedMicroseconds)}',
    );
  }

  void _markDocumentVisible(WebUri? url, {required String phase}) {
    _loadTimeout?.cancel();
    if (!mounted || _visibleDocumentGeneration == _documentLoadGeneration) {
      return;
    }
    _visibleDocumentGeneration = _documentLoadGeneration;
    setState(() {
      _isPageLoading = false;
      _hasRenderedDocument = true;
    });
    debugPrint(
      'Dictionary WebView first visible: headword=${widget.article.headword}; '
      'url=${url?.rawValue}; phase=$phase; '
      'renderMs=${_elapsedMilliseconds(_webViewNavigationStartedMicroseconds)}; '
      'documentTotalMs=${_elapsedMilliseconds(_documentLoadStartedMicroseconds)}',
    );
  }

  Future<void> _finishDocumentSetup(
    InAppWebViewController controller,
    WebUri? url,
    int generation,
  ) async {
    await _applyTextScale(controller);
    if (widget.fitDocumentHeight) {
      await _installDocumentHeightObserver(controller);
    }
    await _installReadingScrollObserver(controller);
    Object? textLength;
    if (widget.localScriptCompatibilityEnabled) {
      try {
        textLength = await controller.evaluateJavascript(
          source: 'document.body ? document.body.innerText.trim().length : -1',
        );
      } catch (error) {
        debugPrint('Dictionary WebView inspection failed: $error');
      }
    }
    debugPrint(
      'Dictionary WebView setup finished: ${url?.rawValue}; '
      'textLength=$textLength; '
      'renderMs=${_elapsedMilliseconds(_webViewNavigationStartedMicroseconds)}; '
      'documentTotalMs=${_elapsedMilliseconds(_documentLoadStartedMicroseconds)}',
    );
    if (!mounted || generation != _documentLoadGeneration) {
      return;
    }
    final isEmpty = textLength is num && textLength <= 0;
    if (isEmpty) {
      setState(() {
        _showFallback = true;
        _fallbackReason = '富文本页面已加载，但没有产生可见正文。';
      });
    }
    await _applyRequestedPosition(controller);
    if (mounted && generation == _documentLoadGeneration) {
      widget.onDocumentRendered?.call();
    }
  }

  Future<void> _applyRequestedPosition(
    InAppWebViewController controller,
  ) async {
    final recoveryOffset = _pendingRecoveryScrollOffset;
    _pendingRecoveryScrollOffset = null;
    if (recoveryOffset != null) {
      await _scrollToOffset(controller, recoveryOffset);
      return;
    }
    final initialAnchor = widget.initialAnchor;
    if (initialAnchor != null && initialAnchor.isNotEmpty) {
      await _scrollToAnchor(controller, initialAnchor);
    } else if (widget.initialScrollOffset case final offset?) {
      await _scrollToOffset(controller, offset);
    }
  }

  Future<void> _loadArticleDocument(
    InAppWebViewController controller,
  ) async {
    final generation = ++_documentLoadGeneration;
    // Every navigation, including a refresh of a retained reader, must hide
    // the unscaled HTML. Without this reset, only the first document in a
    // WebView gets the opaque loading cover and later entries visibly grow
    // from the publisher's base size to the user's selected size.
    if (mounted) {
      setState(() {
        _isPageLoading = true;
        if (_readerPlatformPolicy.revealArticleAfterSetup) {
          _hasRenderedDocument = false;
        }
        _showFallback = false;
      });
    }
    _armLoadTimeout();
    _clearCachedSelection();
    _lastKnownScrollOffset = 0;
    _documentLoadStartedMicroseconds = DateTime.now().microsecondsSinceEpoch;
    _webViewNavigationStartedMicroseconds = null;
    final article = widget.article;
    final localScriptCompatibilityEnabled =
        widget.localScriptCompatibilityEnabled;
    try {
      final sessionTimer = Stopwatch()..start();
      final session = await DictionaryContentServer.instance.openSession(
        engine: widget.engine,
        mdxPath: article.mdxPath,
      );
      sessionTimer.stop();
      if (!mounted || generation != _documentLoadGeneration) {
        session.close();
        return;
      }
      _contentSession?.close();
      _contentSession = session;
      final documentTimer = Stopwatch()..start();
      final document = buildArticleDocument(
        article.html,
        localScriptCompatibilityEnabled: localScriptCompatibilityEnabled,
        resourceBaseUrl: session.resourceBaseUri.toString(),
        textScale: widget.textScale,
      );
      documentTimer.stop();
      session.setDocument(document);
      _webViewNavigationStartedMicroseconds =
          DateTime.now().microsecondsSinceEpoch;
      final articleUrl = WebUri(session.articleUri.toString());
      final submissionTimer = Stopwatch()..start();
      if (Platform.isWindows) {
        // WebView2 assigns loadData an opaque document origin even when a
        // base/history URL is supplied. That conflicts with the article CSP's
        // same-origin rule and blocks publisher CSS, fonts and scripts. Load
        // the document from the loopback session so its origin and resources
        // are genuinely identical.
        await controller.loadUrl(
          urlRequest: URLRequest(url: articleUrl),
        );
      } else {
        // Mobile readers keep the direct submission path: their WebViews
        // honor the supplied base URL and avoid another large UTF-8 transfer.
        await controller.loadData(
          data: document,
          mimeType: 'text/html',
          encoding: 'utf-8',
          baseUrl: articleUrl,
          historyUrl: articleUrl,
        );
      }
      submissionTimer.stop();
      if (!mounted || generation != _documentLoadGeneration) {
        return;
      }
      debugPrint(
        'Dictionary WebView document submitted: headword=${article.headword}; '
        'sessionMs=${sessionTimer.elapsedMilliseconds}; '
        'buildMs=${documentTimer.elapsedMilliseconds}; '
        'submitMs=${submissionTimer.elapsedMilliseconds}',
      );
    } catch (error) {
      debugPrint('Dictionary WebView document submission failed: $error');
      if (mounted && generation == _documentLoadGeneration) {
        _loadTimeout?.cancel();
        setState(() {
          _isPageLoading = false;
          _fallbackReason = '富文本页面无法启动：$error';
          _showFallback = true;
        });
      }
    }
  }

  int? _elapsedMilliseconds(int? startedMicroseconds) {
    if (startedMicroseconds == null) return null;
    return ((DateTime.now().microsecondsSinceEpoch - startedMicroseconds) /
            Duration.microsecondsPerMillisecond)
        .round();
  }

  Future<void> _recoverAfterForeground({required bool forceReload}) async {
    if (!_readerPlatformPolicy.recoverReaderAfterForeground) return;
    final controller = _webViewController;
    if (controller == null) return;
    await _recoverContent(
      controller,
      forceReload: forceReload,
      reason: 'application-resumed',
    );
  }

  void _handleWebContentProcessTermination(
    InAppWebViewController controller,
  ) {
    final canRecover =
        _webContentRecoveryLimiter.registerTermination(DateTime.now());
    final attempts = _webContentRecoveryLimiter.recentTerminationCount;
    ReaderDiagnostics.instance.record(
      'web-content-process-terminated',
      data: {
        'dictionary': widget.article.dictionaryName,
        'headword': widget.article.headword,
        'htmlCodeUnits': widget.article.html.length,
        'recentTerminations': attempts,
        'automaticRecovery': canRecover,
      },
    );
    if (!canRecover) {
      _documentLoadGeneration++;
      _loadTimeout?.cancel();
      unawaited(controller.stopLoading());
      if (mounted) {
        setState(() {
          _isPageLoading = false;
          _showFallback = true;
          _fallbackReason = '词典网页内容连续停止，已切换到简化文本以避免反复重载。';
        });
      }
      return;
    }
    debugPrint(
      'Dictionary WebView content process terminated; rebuilding '
      '${widget.article.headword} (attempt $attempts).',
    );
    unawaited(
      _recoverContent(
        controller,
        forceReload: true,
        reason: 'web-content-process-terminated',
      ),
    );
  }

  Future<void> _recoverContent(
    InAppWebViewController controller, {
    required bool forceReload,
    required String reason,
  }) {
    final recovery = _contentRecovery;
    if (recovery != null) return recovery;

    late final Future<void> nextRecovery;
    nextRecovery = _performContentRecovery(
      controller,
      forceReload: forceReload,
      reason: reason,
    ).whenComplete(() {
      if (identical(_contentRecovery, nextRecovery)) {
        _contentRecovery = null;
      }
    });
    _contentRecovery = nextRecovery;
    return nextRecovery;
  }

  Future<void> _performContentRecovery(
    InAppWebViewController controller, {
    required bool forceReload,
    required String reason,
  }) async {
    if (!mounted) return;
    if (!forceReload && await _documentResourcesAreHealthy(controller)) {
      await _applyTextScale(controller);
      return;
    }

    final scrollOffset = await _readScrollOffset();
    if (!mounted) return;
    _pendingRecoveryScrollOffset = scrollOffset;
    _isPageLoading = true;
    _showFallback = false;
    _armLoadTimeout();
    setState(() {});
    debugPrint(
      'Dictionary WebView recovery: reason=$reason; '
      'headword=${widget.article.headword}; scrollOffset=$scrollOffset',
    );
    ReaderDiagnostics.instance.record(
      'article-recovery',
      data: {
        'reason': reason,
        'dictionary': widget.article.dictionaryName,
        'headword': widget.article.headword,
        'htmlCodeUnits': widget.article.html.length,
        'scrollOffset': scrollOffset,
      },
    );
    await _loadArticleDocument(controller);
  }

  Future<void> _releaseTransientResources() async {
    _audioRequestGeneration++;
    _lastAudioResourcePath = null;
    _lastAudioRequestMilliseconds = 0;
    final player = _audioPlayer;
    _audioPlayer = null;
    if (mounted && _lastSelectedText != null) {
      setState(_clearCachedSelection);
    } else {
      _clearCachedSelection();
    }
    try {
      await player?.dispose();
    } catch (error) {
      debugPrint('Dictionary audio release failed: $error');
    }
    try {
      await _textToSpeech.stop();
    } catch (error) {
      debugPrint('Dictionary speech release failed: $error');
    }
    try {
      await _removeActiveAudioCache();
    } catch (error) {
      debugPrint('Dictionary audio cache release failed: $error');
    }
  }

  Future<bool> _documentResourcesAreHealthy(
    InAppWebViewController controller,
  ) async {
    try {
      final status = await controller.evaluateJavascript(
        source: '''
(() => {
  const styles = Array.from(
    document.querySelectorAll('link[rel~="stylesheet"]')
  );
  return {
    readyState: document.readyState,
    bodyTextLength: document.body
      ? String(document.body.innerText || '').trim().length
      : 0,
    stylesheetCount: styles.length,
    loadedStylesheetCount: styles.filter((link) => Boolean(link.sheet)).length
  };
})();
''',
      );
      return dictionaryDocumentResourcesHealthyForTesting(status);
    } catch (error) {
      debugPrint('Dictionary WebView foreground health check failed: $error');
      return false;
    }
  }

  Future<void> _installReadingScrollObserver(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: '''
(() => {
  if (window.__lumalexReaderScrollObserverInstalled) return;
  window.__lumalexReaderScrollObserverInstalled = true;
  let previousOffset = window.scrollY || 0;
  let lastSentAt = 0;
  window.addEventListener('scroll', () => {
    const offset = window.scrollY || document.documentElement.scrollTop || 0;
    if (Math.abs(offset - previousOffset) < 14) return;
    previousOffset = offset;
    const now = Date.now();
    if (now - lastSentAt < 240) return;
    lastSentAt = now;
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      bridge.callHandler('$_readingScrollHandlerName', offset);
    }
  }, { passive: true });
})();
''',
      );
    } catch (error) {
      debugPrint('Dictionary reader scroll observer failed: $error');
    }
  }

  Future<void> _installDocumentHeightObserver(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(
        source: '''
(() => {
  let scheduledFrame = 0;
  const measureHeight = () => {
    scheduledFrame = 0;
    const body = document.body;
    const root = document.documentElement;
    if (!body || !root || !window.flutter_inappwebview) return;
    const scrollTop = window.scrollY || root.scrollTop || body.scrollTop || 0;
    let contentBottom = 0;
    const includeRect = (rect) => {
      if (rect && (rect.width > 0 || rect.height > 0)) {
        contentBottom = Math.max(contentBottom, rect.bottom + scrollTop);
      }
    };
    const textWalker = document.createTreeWalker(
      body,
      NodeFilter.SHOW_TEXT
    );
    const textRange = document.createRange();
    let textNode = textWalker.nextNode();
    while (textNode) {
      if (textNode.nodeValue && textNode.nodeValue.trim()) {
        const parent = textNode.parentElement;
        const style = parent ? getComputedStyle(parent) : null;
        if (!style ||
            (style.display !== 'none' && style.visibility !== 'hidden')) {
          try {
            textRange.selectNodeContents(textNode);
            for (const rect of textRange.getClientRects()) includeRect(rect);
          } catch (_) {}
        }
      }
      textNode = textWalker.nextNode();
    }
    textRange.detach();
    const measuredElements = [root, body, ...body.querySelectorAll('*')];
    const visualTags = new Set([
      'IMG', 'SVG', 'VIDEO', 'AUDIO', 'CANVAS', 'IFRAME', 'HR', 'INPUT'
    ]);
    for (const element of measuredElements) {
      const style = getComputedStyle(element);
      if (style.display === 'none' ||
          style.visibility === 'hidden' ||
          style.position === 'fixed') continue;
      const rect = element.getBoundingClientRect();
      if (visualTags.has(element.tagName)) includeRect(rect);
      const clientHeight = element.clientHeight || rect.height || 0;
      const scrollHeight = element.scrollHeight || 0;
      if (scrollHeight > clientHeight + 2) {
        contentBottom = Math.max(
          contentBottom,
          rect.top + scrollTop + scrollHeight
        );
      }
    }
    const bodyStyle = getComputedStyle(body);
    const bottomSpacing =
      (parseFloat(bodyStyle.paddingBottom) || 0) +
      (parseFloat(bodyStyle.marginBottom) || 0) + 8;
    const height = Math.ceil(Math.max(1, contentBottom + bottomSpacing));
    window.flutter_inappwebview.callHandler(
      '$_documentHeightHandlerName',
      height
    );
  };
  const reportHeight = () => {
    if (scheduledFrame) return;
    scheduledFrame = requestAnimationFrame(measureHeight);
  };
  if (window.__lumalexDocumentHeightObserver) {
    window.__lumalexDocumentHeightObserver.disconnect();
  }
  if (typeof ResizeObserver !== 'undefined') {
    const observer = new ResizeObserver(reportHeight);
    observer.observe(document.documentElement);
    if (document.body) observer.observe(document.body);
    window.__lumalexDocumentHeightObserver = observer;
  }
  reportHeight();
  setTimeout(reportHeight, 80);
  setTimeout(reportHeight, 300);
})();
''',
      );
    } catch (error) {
      debugPrint('Dictionary document height observation failed: $error');
    }
  }

  Future<void> _handleLoadStart(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final uri = url?.uriValue;
    debugPrint('Dictionary WebView started: ${url?.rawValue}');
    if (isArticleDocumentUrlForTesting(uri) || _isTrustedContentUri(uri)) {
      return;
    }
    await controller.stopLoading();
    if (uri?.scheme == 'sound') {
      await _playSound(uri!);
    }
  }

  Future<void> _refreshSelectedTextFromWebView() async {
    final selected = (await _webViewController?.getSelectedText())?.trim();
    if (selected == null || selected.isEmpty) {
      _lastSelectedText = null;
      _lastSelectedHeadword = null;
      return;
    }
    _lastSelectedText = selected;
    _lastSelectedHeadword = doubleClickLookupHeadwordForTesting(selected);
  }

  Future<void> _handleWindowsSelectionMenuRequest(
    List<dynamic> arguments,
  ) async {
    if (!Platform.isWindows || arguments.isEmpty) return;
    final selected = arguments[0];
    if (selected is! String || selected.trim().isEmpty) return;
    _lastSelectedText = selected.trim();
    _lastSelectedHeadword = doubleClickLookupHeadwordForTesting(selected);
    final renderBox =
        _readerSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final rawX = arguments.elementAtOrNull(2);
    final rawY = arguments.elementAtOrNull(3);
    final localX = rawX is num ? rawX.toDouble() : renderBox.size.width / 2;
    final localY = rawY is num ? rawY.toDouble() : renderBox.size.height / 2;
    final localPosition = Offset(
      localX.clamp(0.0, renderBox.size.width).toDouble(),
      localY.clamp(0.0, renderBox.size.height).toDouble(),
    );
    try {
      await _webViewController?.clearFocus();
    } catch (error) {
      debugPrint('Windows dictionary focus release failed: $error');
    }
    if (!mounted) return;
    unawaited(
      _showWindowsSelectionMenu(
        renderBox.localToGlobal(localPosition),
        refreshSelection: false,
      ),
    );
  }

  Future<void> _showWindowsSelectionMenu(
    Offset globalPosition, {
    bool refreshSelection = true,
  }) async {
    if (_isShowingWindowsSelectionMenu) return;
    _isShowingWindowsSelectionMenu = true;
    try {
      if (refreshSelection) {
        await _refreshSelectedTextFromWebView();
      }
      if (!mounted || _lastSelectedText == null) return;
      final overlay = Overlay.of(context).context.findRenderObject();
      if (overlay is! RenderBox) return;
      final localPosition = overlay.globalToLocal(globalPosition);
      final x = localPosition.dx.clamp(0.0, overlay.size.width).toDouble();
      final y = localPosition.dy.clamp(0.0, overlay.size.height).toDouble();
      final action = await showMenu<_WindowsSelectionMenuAction>(
        context: context,
        position: RelativeRect.fromLTRB(
          x,
          y,
          overlay.size.width - x,
          overlay.size.height - y,
        ),
        items: const [
          PopupMenuItem(
            value: _WindowsSelectionMenuAction.copy,
            height: 48,
            child: Row(
              children: [
                Icon(Icons.copy_outlined),
                SizedBox(width: 12),
                Text('复制'),
              ],
            ),
          ),
          PopupMenuItem(
            value: _WindowsSelectionMenuAction.lookup,
            height: 48,
            child: Row(
              children: [
                Icon(Icons.search),
                SizedBox(width: 12),
                Text('查词'),
              ],
            ),
          ),
        ],
      );
      if (!mounted || action == null) return;
      ReaderDiagnostics.instance.record(
        'windows-flutter-selection-action',
        data: {'action': action.name},
      );
      switch (action) {
        case _WindowsSelectionMenuAction.copy:
          await _copyCachedSelection();
        case _WindowsSelectionMenuAction.lookup:
          _lookupCachedSelection();
      }
    } catch (error) {
      debugPrint('Windows dictionary selection menu failed: $error');
    } finally {
      _isShowingWindowsSelectionMenu = false;
    }
  }

  Future<void> _handleWindowsSelectionAction(List<dynamic> arguments) async {
    if (!Platform.isWindows || arguments.length < 2) return;
    final action = arguments[0];
    final selected = arguments[1];
    if (action is! String || selected is! String) return;
    final text = selected.trim();
    if (text.isEmpty) return;
    _lastSelectedText = text;
    _lastSelectedHeadword = doubleClickLookupHeadwordForTesting(text);
    if (action == 'copy') {
      await _copyCachedSelection();
    } else if (action == 'lookup') {
      _lookupCachedSelection();
    }
  }

  void _lookupSelectedTextFromContextMenu() {
    if (Platform.isIOS) {
      _lookupCachedSelection();
      return;
    }
    final callback = widget.onOpenHeadword;
    if (callback == null || _isSelectionLookup) {
      return;
    }
    _isSelectionLookup = true;
    unawaited(_dispatchSelectionLookup(callback));
  }

  Future<void> _dispatchSelectionLookup(
    Future<void> Function(String headword, String? anchor, double scrollOffset)
        callback,
  ) async {
    try {
      // Android's native menu remains in place, so return from the action
      // before beginning a new dictionary navigation.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      final headword = _lastSelectedHeadword;
      if (headword == null) {
        return;
      }
      await _openCachedSelection(callback, headword, _lastKnownScrollOffset);
    } catch (error) {
      debugPrint('Dictionary selection lookup failed: $error');
    } finally {
      _isSelectionLookup = false;
    }
  }

  void _lookupCachedSelection() {
    final callback = widget.onOpenHeadword;
    final headword = _lastSelectedHeadword;
    if (callback == null || headword == null || _isSelectionLookup) {
      return;
    }
    _isSelectionLookup = true;
    if (mounted) {
      setState(_clearCachedSelection);
    }
    unawaited(
      _openCachedSelection(callback, headword, _lastKnownScrollOffset)
          .whenComplete(() => _isSelectionLookup = false),
    );
  }

  Future<void> _copyCachedSelection() async {
    final selected = _lastSelectedText;
    if (selected == null || selected.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: selected));
      if (mounted) {
        setState(_clearCachedSelection);
      }
    } catch (error) {
      debugPrint('Dictionary cached selection copy failed: $error');
    }
  }

  void _clearCachedSelection() {
    _lastSelectedText = null;
    _lastSelectedHeadword = null;
    _lastSelectionRect = null;
    _lastSelectionViewport = null;
  }

  Widget _buildIosSelectionToolbar(BuildContext context) {
    const toolbarWidth = 144.0;
    const toolbarHeight = 44.0;
    const edgeInset = 8.0;
    const selectionGap = 8.0;
    final selectionRect = _lastSelectionRect!;
    final selectionViewport = _lastSelectionViewport!;
    final colorScheme = Theme.of(context).colorScheme;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = selectionViewport.width;
          final viewportHeight = selectionViewport.height;
          final scaleX =
              viewportWidth > 0 ? constraints.maxWidth / viewportWidth : 1.0;
          final scaleY =
              viewportHeight > 0 ? constraints.maxHeight / viewportHeight : 1.0;
          final rect = Rect.fromLTRB(
            selectionRect.left * scaleX,
            selectionRect.top * scaleY,
            selectionRect.right * scaleX,
            selectionRect.bottom * scaleY,
          );
          final maxLeft = (constraints.maxWidth - toolbarWidth - edgeInset)
              .clamp(edgeInset, double.infinity)
              .toDouble();
          final left = (rect.center.dx - toolbarWidth / 2)
              .clamp(edgeInset, maxLeft)
              .toDouble();
          var top = rect.top - toolbarHeight - selectionGap;
          if (top < edgeInset) {
            top = rect.bottom + selectionGap;
          }
          final maxTop = (constraints.maxHeight - toolbarHeight - edgeInset)
              .clamp(edgeInset, double.infinity)
              .toDouble();
          top = top.clamp(edgeInset, maxTop).toDouble();

          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: Material(
                  elevation: 8,
                  color: colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: toolbarWidth,
                    height: toolbarHeight,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: _copyCachedSelection,
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.onInverseSurface,
                              shape: const RoundedRectangleBorder(),
                            ),
                            child: const Text('复制'),
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: colorScheme.onInverseSurface.withValues(
                            alpha: 0.25,
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: _lastSelectedHeadword != null &&
                                    !_isSelectionLookup &&
                                    widget.onOpenHeadword != null
                                ? _lookupCachedSelection
                                : null,
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.onInverseSurface,
                              disabledForegroundColor: colorScheme
                                  .onInverseSurface
                                  .withValues(alpha: 0.38),
                              shape: const RoundedRectangleBorder(),
                            ),
                            child: const Text('查词'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openCachedSelection(
    Future<void> Function(String headword, String? anchor, double scrollOffset)
        callback,
    String headword,
    double scrollOffset,
  ) async {
    try {
      await callback(headword, null, scrollOffset);
    } catch (error) {
      debugPrint('Dictionary selection lookup failed: $error');
    }
  }

  Future<void> _copySelectedTextFromContextMenu() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final selected = (await controller.getSelectedText())?.trim();
      if (selected == null || selected.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: selected));
      await controller.clearFocus();
    } catch (error) {
      debugPrint('Dictionary selection copy failed: $error');
    }
  }

  Widget _buildFallback(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fallbackReason,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 16),
                Text(_plainText(widget.article.html)),
              ],
            ),
          ),
        ),
      );

  Future<NavigationActionPolicy> _handleNavigation(
    InAppWebViewController controller,
    String? rawUrl,
  ) async {
    debugPrint('Dictionary navigation requested: $rawUrl');
    final selectionLookup = windowsSelectionLookupRequestForTesting(rawUrl);
    if (Platform.isWindows && selectionLookup != null) {
      final headword = doubleClickLookupHeadwordForTesting(
        selectionLookup.text,
      );
      _lastSelectedText = selectionLookup.text;
      _lastSelectedHeadword = headword;
      ReaderDiagnostics.instance.record(
        'windows-selection-lookup',
        data: {'accepted': headword != null},
      );
      _lookupCachedSelection();
      return NavigationActionPolicy.CANCEL;
    }
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (isArticleDocumentUrlForTesting(uri) || _isTrustedContentUri(uri)) {
      return NavigationActionPolicy.ALLOW;
    }

    if (uri?.scheme.toLowerCase() == 'sound') {
      unawaited(_playSound(uri!));
      return NavigationActionPolicy.CANCEL;
    }

    final link = rawUrl == null ? null : dictionaryLinkForTesting(rawUrl);
    if (link != null) {
      unawaited(_followDictionaryLink(controller, link));
    }
    // External pages and unrecognized schemes never replace local content.
    return NavigationActionPolicy.CANCEL;
  }

  bool _isTrustedContentUri(Uri? uri) =>
      uri != null && (_contentSession?.owns(uri) ?? false);

  Future<void> _applyTextScale(InAppWebViewController controller) async {
    final scale = widget.textScale.clamp(0.6, 2.0);
    try {
      await controller.evaluateJavascript(
        source: '''
          if (typeof window.__lumalexSetTextScale === 'function') {
            window.__lumalexSetTextScale($scale);
          }
        ''',
      );
    } catch (error) {
      debugPrint('Dictionary text scaling failed: $error');
    }
  }

  Future<void> _followDictionaryLink(
    InAppWebViewController controller,
    ({String? headword, String? anchor}) link,
  ) async {
    final headword = link.headword?.trim();
    final anchor = link.anchor;
    if (headword == null || headword.isEmpty) {
      await _scrollToAnchor(controller, anchor ?? '');
      return;
    }
    if (anchor != null &&
        headword.toLowerCase() == widget.article.headword.toLowerCase()) {
      await _scrollToAnchor(controller, anchor);
      return;
    }
    if (_isFollowingLink) {
      return;
    }

    if (mounted) {
      setState(() => _isFollowingLink = true);
    }
    try {
      final onOpenHeadword = widget.onOpenHeadword;
      if (onOpenHeadword != null) {
        final scrollOffset = await _readScrollOffset();
        await onOpenHeadword(headword, anchor, scrollOffset);
        return;
      }
      final articles = await widget.engine.lookup(
        headword,
        mdxPath: widget.article.mdxPath,
      );
      if (!mounted) {
        return;
      }
      if (articles.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('词典中没有找到“$headword”。')),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ArticlePage(
            article: articles.first,
            engine: widget.engine,
            localScriptCompatibilityEnabled:
                widget.localScriptCompatibilityEnabled,
            initialAnchor: anchor,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开这个词典链接。')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isFollowingLink = false);
      }
    }
  }

  Future<void> _scrollToAnchor(
    InAppWebViewController controller,
    String anchor,
  ) async {
    final encoded = jsonEncode(anchor);
    try {
      await controller.evaluateJavascript(
        source: '''
          (() => {
            const anchor = $encoded;
            if (!anchor) {
              window.scrollTo({top: 0, behavior: 'smooth'});
              return;
            }
            const byId = document.getElementById(anchor);
            const byName = Array.from(document.getElementsByName(anchor))[0];
            const target = byId || byName;
            if (target) {
              target.scrollIntoView({block: 'start', behavior: 'smooth'});
            }
          })();
        ''',
      );
    } catch (_) {
      // A missing or malformed anchor must not replace the current article.
    }
  }

  Future<double> _readScrollOffset() async {
    final controller = _webViewController;
    if (controller == null) {
      return 0;
    }
    try {
      final result = await controller.evaluateJavascript(
        source: '''
          window.scrollY || document.documentElement.scrollTop || 0;
        ''',
      );
      return result is num ? result.toDouble() : 0;
    } catch (error) {
      debugPrint('Dictionary scroll position read failed: $error');
      return 0;
    }
  }

  Future<void> _scrollToOffset(
    InAppWebViewController controller,
    double offset,
  ) async {
    if (!offset.isFinite || offset <= 0) {
      return;
    }
    try {
      await controller.evaluateJavascript(
        source: 'window.scrollTo(0, ${offset.clamp(0, double.maxFinite)});',
      );
    } catch (error) {
      debugPrint('Dictionary scroll position restore failed: $error');
    }
  }

  bool _isExpectedNavigationCancellation(
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (request.isForMainFrame != true) {
      return false;
    }
    if (error.type == WebResourceErrorType.CANCELLED) {
      return true;
    }
    final uri = request.url.uriValue;
    return !isArticleDocumentUrlForTesting(uri) && !_isTrustedContentUri(uri);
  }

  Future<void> _playSound(Uri uri) async {
    final resourcePath = _soundResourcePath(uri);
    if (resourcePath == null) {
      _showAudioError();
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAudioResourcePath == resourcePath &&
        now - _lastAudioRequestMilliseconds < 400) {
      return;
    }
    _lastAudioResourcePath = resourcePath;
    _lastAudioRequestMilliseconds = now;
    final request = ++_audioRequestGeneration;

    try {
      await _textToSpeech.stop();
      final resource = await widget.engine.readResource(
        resourcePath,
        maxBytes: _maxResourceBytes,
        mdxPath: widget.article.mdxPath,
      );
      if (!mounted || request != _audioRequestGeneration) {
        return;
      }
      if (resource == null) {
        debugPrint('Dictionary audio resource not found: $resourcePath');
        _showAudioError();
        return;
      }

      final player = _audioPlayer ??= AudioPlayer();
      // Do not stop a brand-new player. On Windows that immediately releases
      // the native MediaPlayer before its first source is loaded, and the cold
      // deactivate/reactivate cycle can swallow the first playback request.
      // Pausing an existing pronunciation keeps the decoder warm while still
      // interrupting it cleanly.
      if (player.playing) {
        await player.pause();
      }
      if (!mounted || request != _audioRequestGeneration) {
        return;
      }
      await _removeActiveAudioCache();

      // Supplying a real local filename lets each platform pick the correct
      // decoder without opening a localhost proxy or any network connection.
      final directory = await Directory.systemTemp.createTemp(
        'local_dictionary_audio_',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'pronunciation.${_audioExtension(resourcePath)}',
      );
      await file.writeAsBytes(resource.bytes, flush: true);
      if (!mounted || request != _audioRequestGeneration) {
        await directory.delete(recursive: true);
        return;
      }
      _activeAudioDirectory = directory;

      await player.setFilePath(
        file.path,
        initialPosition: Duration.zero,
      );
      if (!mounted || request != _audioRequestGeneration) {
        return;
      }
      // just_audio_windows 0.2.x can deliver the final `playing: false` load
      // event just after setFilePath completes. Starting immediately lets that
      // stale event cancel the first play request. Give the Windows event
      // channel one short settling window before asking it to play.
      if (Platform.isWindows) {
        await Future<void>.delayed(_windowsAudioLoadStabilizationDelay);
      }
      if (!mounted || request != _audioRequestGeneration) {
        return;
      }
      unawaited(
        player.play().catchError((Object error) {
          debugPrint('Dictionary audio playback failed: $error');
          if (request == _audioRequestGeneration) {
            _showAudioError();
          }
        }),
      );
    } catch (error) {
      debugPrint('Dictionary audio setup failed: $error');
      if (request == _audioRequestGeneration) {
        _showAudioError();
      }
    }
  }

  Future<void> _speakExample(String text, String locale) async {
    _audioRequestGeneration++;
    try {
      await _audioPlayer?.stop();
      await _textToSpeech.speak(text, locale: locale);
    } on PlatformException catch (error) {
      debugPrint(
        'Dictionary example TTS failed: ${error.code} ${error.message}',
      );
      _showTextToSpeechError(error.message);
    } catch (error) {
      debugPrint('Dictionary example TTS failed: $error');
      _showTextToSpeechError(null);
    }
  }

  Future<void> _stopPlayback() async {
    _audioRequestGeneration++;
    try {
      await _audioPlayer?.stop();
    } catch (error) {
      debugPrint('Dictionary audio stop failed: $error');
    }
    try {
      await _textToSpeech.stop();
    } catch (error) {
      debugPrint('Dictionary speech stop failed: $error');
    }
  }

  Future<void> _removeActiveAudioCache() async {
    final directory = _activeAudioDirectory;
    _activeAudioDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _showAudioError() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法播放此发音文件。')),
    );
  }

  void _showTextToSpeechError(String? detail) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          detail?.trim().isNotEmpty == true
              ? detail!
              : '无法使用系统英语语音。请安装英语文字转语音语音包后重试。',
        ),
      ),
    );
  }

  Future<CustomSchemeResponse> _loadCustomSchemeResource(Uri uri) async {
    final resourcePath = switch (uri.scheme) {
      'dictres' when uri.host == 'resource' => uri.path,
      'sound' => _soundResourcePath(uri),
      _ => null,
    };
    if (resourcePath == null) return _emptyResource();

    try {
      final resource = await widget.engine.readResource(
        resourcePath,
        maxBytes: _maxResourceBytes,
        mdxPath: widget.article.mdxPath,
      );
      if (resource == null) {
        return _emptyResource();
      }
      final encoding = _textEncoding(resource.mimeType);
      return encoding == null
          ? CustomSchemeResponse(
              contentType: resource.mimeType,
              data: resource.bytes,
            )
          : CustomSchemeResponse(
              contentType: resource.mimeType,
              contentEncoding: encoding,
              data: resource.bytes,
            );
    } catch (_) {
      // A malformed or oversized attachment should only fail that attachment;
      // it must not make the article page or its surrounding app unsafe.
      return _emptyResource();
    }
  }
}

String _plainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

@visibleForTesting
({String text, String? headword, Rect rect, Size viewport})?
    dictionarySelectionForTesting(Object? rawArguments) {
  if (rawArguments is! List || rawArguments.length < 7) return null;
  final rawText = rawArguments[0];
  if (rawText is! String) return null;
  final text = rawText.trim();
  if (text.isEmpty || text.length > 16384) return null;

  final coordinates = rawArguments.skip(1).take(6).toList(growable: false);
  if (coordinates.any((value) => value is! num || !value.isFinite)) {
    return null;
  }
  final left = (coordinates[0] as num).toDouble();
  final top = (coordinates[1] as num).toDouble();
  final right = (coordinates[2] as num).toDouble();
  final bottom = (coordinates[3] as num).toDouble();
  final viewportWidth = (coordinates[4] as num).toDouble();
  final viewportHeight = (coordinates[5] as num).toDouble();
  if (right < left ||
      bottom < top ||
      viewportWidth <= 0 ||
      viewportHeight <= 0) {
    return null;
  }

  return (
    text: text,
    headword: doubleClickLookupHeadwordForTesting(text),
    rect: Rect.fromLTRB(left, top, right, bottom),
    viewport: Size(viewportWidth, viewportHeight),
  );
}

@visibleForTesting
bool dictionaryDocumentResourcesHealthyForTesting(Object? rawStatus) {
  if (rawStatus is! Map) return false;
  final readyState = rawStatus['readyState'];
  final bodyTextLength = rawStatus['bodyTextLength'];
  final stylesheetCount = rawStatus['stylesheetCount'];
  final loadedStylesheetCount = rawStatus['loadedStylesheetCount'];
  final documentReady = readyState == 'interactive' || readyState == 'complete';
  if (!documentReady || bodyTextLength is! num || bodyTextLength <= 0) {
    return false;
  }
  if (stylesheetCount is! num || loadedStylesheetCount is! num) {
    return false;
  }
  return stylesheetCount <= 0 || loadedStylesheetCount >= stylesheetCount;
}

String? _soundResourcePath(Uri uri) {
  return dictionarySoundResourcePath(uri.toString());
}

/// Converts the non-standard sound links used in MDict HTML into an MDD key.
///
/// Oxford packages commonly use `sound://file.mp3`, while other publishers
/// use `sound:file.mp3`. MDD filenames may themselves contain `#`, so this is
/// deliberately not parsed as a conventional URL path: an unescaped hash is
/// part of the resource key, not a browser fragment.
String? dictionarySoundResourcePath(String rawUri) {
  final match =
      RegExp(r'^\s*sound:(.*)$', caseSensitive: false).firstMatch(rawUri);
  if (match == null) {
    return null;
  }

  var value = match.group(1) ?? '';
  if (value.startsWith('//')) {
    value = value.substring(2);
  }
  final queryIndex = value.indexOf('?');
  if (queryIndex >= 0) {
    final path = value.substring(0, queryIndex);
    final query = value.substring(queryIndex + 1);
    final queryPath = _soundPathFromQuery(query);
    value = queryPath ?? path;
  }
  if (value.isEmpty) {
    return null;
  }
  try {
    final decoded = Uri.decodeComponent(value);
    return decoded.isEmpty ? null : decoded;
  } on FormatException {
    return null;
  }
}

String? _soundPathFromQuery(String query) {
  try {
    final values = Uri.splitQueryString(query);
    for (final name in const ['file', 'path', 'src', 'audio']) {
      final value = values[name];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
  } on FormatException {
    // Fall through to the path portion of the sound URL.
  }
  return null;
}

@visibleForTesting
bool isArticleDocumentUrlForTesting(Uri? uri) =>
    uri != null &&
    uri.scheme == 'about' &&
    uri.path == 'blank' &&
    !uri.hasQuery &&
    uri.fragment.isEmpty;

/// Converts the link conventions commonly embedded in MDX records into a
/// local headword lookup and an optional destination inside that record.
({String? headword, String? anchor})? dictionaryLinkForTesting(String rawUrl) {
  final raw = rawUrl.trim();
  if (raw.isEmpty) {
    return null;
  }

  final parsed = Uri.tryParse(raw);
  if (parsed != null &&
      ((parsed.scheme == 'dictres' && parsed.host == 'resource') ||
          parsed.scheme == 'about') &&
      parsed.fragment.isNotEmpty) {
    return (headword: null, anchor: _decodeLinkPart(parsed.fragment));
  }
  if (raw.startsWith('#')) {
    return (headword: null, anchor: _decodeLinkPart(raw.substring(1)));
  }

  final separator = raw.indexOf(':');
  if (separator <= 0) {
    return null;
  }
  final scheme = raw.substring(0, separator).toLowerCase();
  if (scheme == 'x-dictionary') {
    const lookupPrefix = 'x-dictionary:r:';
    if (!raw.toLowerCase().startsWith(lookupPrefix)) {
      return null;
    }
    final target = raw.substring(lookupPrefix.length);
    return _splitDictionaryTarget(target);
  }
  if (!const {'entry', 'bword', 'lookup', 'mdict'}.contains(scheme)) {
    return null;
  }

  var target = raw.substring(separator + 1);
  if (target.startsWith('//')) {
    target = target.substring(2);
  }
  while (target.startsWith('/')) {
    target = target.substring(1);
  }
  return _splitDictionaryTarget(target);
}

({String? headword, String? anchor}) _splitDictionaryTarget(String target) {
  final hash = target.indexOf('#');
  final rawHeadword = hash < 0 ? target : target.substring(0, hash);
  final rawAnchor = hash < 0 ? null : target.substring(hash + 1);
  final query = rawHeadword.indexOf('?');
  final headwordWithoutQuery =
      query < 0 ? rawHeadword : rawHeadword.substring(0, query);
  final headword = _decodeLinkPart(headwordWithoutQuery).trim();
  return (
    headword: headword.isEmpty ? null : headword,
    anchor: rawAnchor == null ? null : _decodeLinkPart(rawAnchor),
  );
}

String _decodeLinkPart(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}

@visibleForTesting
String? soundResourcePathForTesting(Uri uri) => _soundResourcePath(uri);

const _lightColorSchemeBootstrap = r'''
  <script id="dictionary-host-light-theme">
    (() => {
      const nativeMatchMedia = window.matchMedia.bind(window);
      const fixedResult = (media, matches) => {
        const listeners = new Set();
        return {
          media,
          matches,
          onchange: null,
          addListener(listener) {
            if (typeof listener === 'function') listeners.add(listener);
          },
          removeListener(listener) { listeners.delete(listener); },
          addEventListener(type, listener) {
            if (type === 'change' && typeof listener === 'function') {
              listeners.add(listener);
            }
          },
          removeEventListener(type, listener) {
            if (type === 'change') listeners.delete(listener);
          },
          dispatchEvent(event) {
            listeners.forEach((listener) => listener.call(this, event));
            if (typeof this.onchange === 'function') this.onchange(event);
            return !event.defaultPrevented;
          },
        };
      };

      window.matchMedia = (query) => {
        const media = String(query);
        const normalized = media.toLowerCase().replace(/\s+/g, '');
        if (normalized === '(prefers-color-scheme:dark)') {
          return fixedResult(media, false);
        }
        if (normalized === '(prefers-color-scheme:light)') {
          return fixedResult(media, true);
        }
        return nativeMatchMedia(media);
      };
    })();
  </script>''';

const _cambridgePresentationDefaults = r'''
  <script id="dictionary-host-cdepe-defaults">
    (() => {
      try {
        // Apply the reading policy before cdepe.js imports its configuration.
        // Boolean options use "1" and "0" in this dictionary's storage layer.
        localStorage.setItem('CDEPE_showTranslation', '1');
        localStorage.setItem('CDEPE_unfoldSense', '1');
        localStorage.setItem('CDEPE_touchToTranslate', '0');
        localStorage.setItem('CDEPE_unfoldBox1', '1');
        localStorage.setItem('CDEPE_unfoldBox2', '0');
        localStorage.setItem('CDEPE_unfoldBox3', '0');
        localStorage.setItem('CDEPE_unfoldBox4', '0');
        localStorage.setItem('CDEPE_unfoldBox5', '0');
        localStorage.setItem('CDEPE_selectNavbarAll', '1');
        localStorage.setItem('CDEPE_selectNavbarDictAll', '1');
      } catch (_) {
        // The publisher defaults remain usable if storage is unavailable.
      }

      // cdepe.js gives an already-selected navigation item two unrelated
      // gestures: click toggles all Chinese, and double-click folds/unfolds
      // the entry. Keep inactive items clickable for normal part-of-speech
      // switching, but remove both gestures from the active item.
      const suppressActiveNavigationToggle = (event) => {
        const target = event.target instanceof Element
          ? event.target
          : event.target && event.target.parentElement;
        const item = target && target.closest
          ? target.closest('.cdepe-nav > span, .cdepe-nav-dict > span')
          : null;
        if (!item || !item.classList.contains('active')) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      };
      document.addEventListener('click', suppressActiveNavigationToggle, true);
      document.addEventListener(
        'dblclick',
        suppressActiveNavigationToggle,
        true,
      );
    })();
  </script>''';

const _merriamWebsterPresentationDefaults = r'''
  <script id="dictionary-host-maldpe-defaults">
    (() => {
      try {
        // maldpe.js uses the same interaction model as CDEPE, with its own
        // storage prefix and DOM namespace.
        localStorage.setItem('MALDPE_showTranslation', '1');
        localStorage.setItem('MALDPE_unfoldSense', '1');
        localStorage.setItem('MALDPE_touchToTranslate', '0');
        localStorage.setItem('MALDPE_selectNavbarAll', '1');
      } catch (_) {
        // The publisher defaults remain usable if storage is unavailable.
      }

      const suppressActiveNavigationToggle = (event) => {
        const target = event.target instanceof Element
          ? event.target
          : event.target && event.target.parentElement;
        const item = target && target.closest
          ? target.closest('.maldpe-nav > span')
          : null;
        if (!item || !item.classList.contains('active')) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      };
      document.addEventListener('click', suppressActiveNavigationToggle, true);
      document.addEventListener(
        'dblclick',
        suppressActiveNavigationToggle,
        true,
      );
    })();
  </script>''';

const _dictionaryTextToSpeechResolver = r'''
      const lumalexDictionaryTtsSelector = [
        'a.sound.tts',
        'example-audio-ai a.audio_uk',
        'example-audio-ai a.audio_us',
        'a.sound-ai'
      ].join(',');

      const lumalexDictionaryTtsRequest = (control) => {
        if (!control || typeof control.closest !== 'function') return null;
        let source = control.parentElement;
        let locale = 'en-US';

        if (control.matches('example-audio-ai a.audio_uk, example-audio-ai a.audio_us')) {
          const host = control.closest('example-audio-ai');
          source = host ? host.previousElementSibling : null;
          locale = control.classList.contains('audio_uk') ? 'en-GB' : 'en-US';
        } else if (control.matches('a.sound-ai')) {
          const entry = control.closest('.entryContent[data-dictname]');
          const dictionaryName = entry ? entry.getAttribute('data-dictname') : '';
          locale = String(dictionaryName).includes('(UK)') ? 'en-GB' : 'en-US';
        } else {
          locale = control.classList.contains('pron-uk') ? 'en-GB' : 'en-US';
        }

        if (!source) return null;
        const copy = source.cloneNode(true);
        for (const ignored of copy.querySelectorAll(
          'a.sound, a.sound-ai, example-audio-ai, .gloss, .zh, chn, script'
        )) {
          ignored.remove();
        }
        const text = String(copy.textContent || '').replace(/\s+/g, ' ').trim();
        return text ? {text, locale} : null;
      };
''';

String dictionaryTextToSpeechResolverJavascript() =>
    _dictionaryTextToSpeechResolver;

final String _localSoundBridge = <String>[
  r'''
  <script id="dictionary-host-sound-bridge">
    (() => {
''',
  _dictionaryTextToSpeechResolver,
  r'''
      document.addEventListener('click', (event) => {
        const rawTarget = event.target;
        const target = rawTarget && typeof rawTarget.closest === 'function'
          ? rawTarget
          : rawTarget && rawTarget.parentElement;
        const targetAtPointer = document.elementFromPoint(
          event.clientX,
          event.clientY
        );
        const tts = (target && target.closest
          ? target.closest(lumalexDictionaryTtsSelector)
          : null) || (targetAtPointer && targetAtPointer.closest
            ? targetAtPointer.closest(lumalexDictionaryTtsSelector)
            : null);
        if (tts) {
          event.preventDefault();
          event.stopImmediatePropagation();
          const request = lumalexDictionaryTtsRequest(tts);
          const bridge = window.flutter_inappwebview;
          if (request && bridge && typeof bridge.callHandler === 'function') {
            bridge.callHandler(
              'speakDictionaryExample',
              request.text,
              request.locale
            );
          }
          return;
        }

        const link = target && target.closest ? target.closest('[href]') : null;
        const href = link ? link.getAttribute('href') : null;
        if (!href || !/^sound:/i.test(href)) return;

        event.preventDefault();
        event.stopImmediatePropagation();
        const bridge = window.flutter_inappwebview;
        if (bridge && typeof bridge.callHandler === 'function') {
          bridge.callHandler('playDictionarySound', href);
        } else {
          window.location.href = href;
        }
      }, true);
    })();
  </script>''',
].join();

const _doubleClickLookupBridge = r'''
  <script id="dictionary-host-double-click-lookup">
    (() => {
      const ignoredSelector = [
        'a',
        'button',
        'input',
        'select',
        'textarea',
        '[role="button"]',
        '[contenteditable="true"]',
        '.sound',
        '.speaker',
        '.senseButton',
        '.cdepe-nav',
        '.cdepe-nav-dict',
        '.cdepe-nav-sense',
        '.maldpe-nav',
      ].join(',');

      document.addEventListener('dblclick', (event) => {
        const target = event.target instanceof Element
          ? event.target
          : event.target && event.target.parentElement;
        if (!target || target.closest(ignoredSelector)) return;

        // WebKit finalizes the double-click selection immediately after the
        // event. Read it on the next task so the complete word is available.
        setTimeout(() => {
          const selected = String(window.getSelection() || '').trim();
          const match = selected.match(
            /[\p{L}\p{M}\p{N}]+(?:[\u2019'\-][\p{L}\p{M}\p{N}]+)*/u,
          );
          const headword = match ? match[0] : '';
          if (!headword) return;
          const bridge = window.flutter_inappwebview;
          if (bridge && typeof bridge.callHandler === 'function') {
            bridge.callHandler('lookupDictionaryWord', headword);
          }
        }, 0);
      });
    })();
  </script>''';

const _selectionChangeBridge = r'''
  <script id="dictionary-host-selection-bridge">
    (() => {
      let selectionTimer = 0;
      const publishSelection = () => {
        selectionTimer = 0;
        const selection = window.getSelection();
        const selected = String(selection || '').trim();
        const bridge = window.flutter_inappwebview;
        if (!bridge || typeof bridge.callHandler !== 'function') return;
        if (!selection || !selection.rangeCount || !selected) {
          bridge.callHandler('dictionaryReaderSelectionChanged', '');
          return;
        }
        const rect = selection.getRangeAt(0).getBoundingClientRect();
        bridge.callHandler(
          'dictionaryReaderSelectionChanged',
          selected,
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
          window.innerWidth,
          window.innerHeight
        );
      };
      document.addEventListener('selectionchange', () => {
        if (selectionTimer) clearTimeout(selectionTimer);
        selectionTimer = setTimeout(publishSelection, 0);
      });
    })();
  </script>''';

const _windowsSelectionContextMenuBridge = r'''
  <script id="dictionary-host-windows-selection-menu">
    (() => {
      let menu = null;
      const closeMenu = () => {
        if (menu) menu.remove();
        menu = null;
      };
      const makeButton = (label, action, selected) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.style.cssText = [
          'min-width:72px', 'min-height:44px', 'padding:0 16px',
          'border:0', 'background:transparent', 'color:#ffffff',
          'font:600 14px "Noto Sans SC","Microsoft YaHei UI",sans-serif',
          'cursor:pointer'
        ].join(';');
        button.addEventListener('pointerenter', () => {
          button.style.background = 'rgba(255,255,255,.14)';
        });
        button.addEventListener('pointerleave', () => {
          button.style.background = 'transparent';
        });
        let dispatching = false;
        const dispatch = async (event) => {
          event.preventDefault();
          event.stopPropagation();
          if (dispatching) return;
          dispatching = true;
          button.disabled = true;
          if (action === 'lookup') {
            // Lookup uses WebView2's native navigation callback instead of
            // the JavaScript bridge. The first bridge message in a fresh
            // document can be lost while WebView2 attaches its message
            // channel; NavigationStarting is already active at this point.
            const lookupUrl = new URL(
              '/__lumalex_selection_lookup__', window.location.href
            );
            lookupUrl.searchParams.set('text', selected);
            window.location.assign(lookupUrl.href);
            closeMenu();
            return;
          }
          const bridge = window.flutter_inappwebview;
          try {
            if (bridge && typeof bridge.callHandler === 'function') {
              await bridge.callHandler(
                'dictionaryReaderSelectionAction', action, selected
              );
            }
          } finally {
            closeMenu();
          }
        };
        // Dispatch on pointer-down so WebView focus/selection changes cannot
        // consume the first click. Keep click for keyboard activation, with
        // the guard above preventing duplicate dispatch.
        button.addEventListener('pointerdown', dispatch);
        button.addEventListener('click', dispatch);
        return button;
      };
      document.addEventListener('contextmenu', (event) => {
        const selection = window.getSelection();
        const selected = String(selection || '').trim();
        if (!selection || !selection.rangeCount || !selected) {
          closeMenu();
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        closeMenu();
        menu = document.createElement('div');
        menu.setAttribute('role', 'menu');
        // Host UI is not dictionary content. The text-scaling observer must
        // ignore this temporary subtree; otherwise opening or closing the
        // selection menu needlessly reprocesses the whole article.
        menu.setAttribute('data-lumalex-host-ui', 'selection-menu');
        menu.style.cssText = [
          'position:fixed', 'display:flex', 'z-index:2147483647',
          'overflow:hidden', 'border-radius:10px', 'background:#263232',
          'box-shadow:0 8px 24px rgba(0,0,0,.28)', 'user-select:none'
        ].join(';');
        menu.appendChild(makeButton('复制', 'copy', selected));
        const divider = document.createElement('span');
        divider.style.cssText =
          'width:1px;background:rgba(255,255,255,.22);margin:8px 0';
        menu.appendChild(divider);
        menu.appendChild(makeButton('查词', 'lookup', selected));
        document.body.appendChild(menu);
        const bounds = menu.getBoundingClientRect();
        const left = Math.max(
          8,
          Math.min(event.clientX, window.innerWidth - bounds.width - 8)
        );
        const top = Math.max(
          8,
          Math.min(event.clientY, window.innerHeight - bounds.height - 8)
        );
        menu.style.left = `${left}px`;
        menu.style.top = `${top}px`;
      }, true);
      document.addEventListener('pointerdown', (event) => {
        if (menu && !menu.contains(event.target)) closeMenu();
      }, true);
      document.addEventListener('scroll', closeMenu, true);
      window.addEventListener('blur', closeMenu);
    })();
  </script>''';

String _publisherPresentationDefaults(String articleHtml) {
  final normalized = articleHtml.toLowerCase();
  if (normalized.contains('cdepe.css') ||
      normalized.contains('cdepe.js') ||
      normalized.contains('class="cdepe"') ||
      normalized.contains("class='cdepe'")) {
    return _cambridgePresentationDefaults;
  }
  if (normalized.contains('maldpe.css') ||
      normalized.contains('maldpe.js') ||
      normalized.contains('class="maldpe"') ||
      normalized.contains("class='maldpe'")) {
    return _merriamWebsterPresentationDefaults;
  }
  return '';
}

@visibleForTesting
String publisherPresentationDefaultsForTesting(String articleHtml) =>
    _publisherPresentationDefaults(articleHtml);

String _audioExtension(String resourcePath) {
  final dot = resourcePath.lastIndexOf('.');
  if (dot < 1 || dot == resourcePath.length - 1) {
    return 'mp3';
  }
  final extension = resourcePath.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,10}$').hasMatch(extension) ? extension : 'mp3';
}

CustomSchemeResponse _emptyResource() => CustomSchemeResponse(
      contentType: 'application/octet-stream',
      data: Uint8List(0),
    );

String? _textEncoding(String mimeType) {
  final normalized = mimeType.toLowerCase();
  return normalized.startsWith('text/') ||
          normalized == 'application/javascript' ||
          normalized == 'application/json'
      ? 'utf-8'
      : null;
}

String _textScaleBootstrap(double initialScale) {
  final scale = initialScale.clamp(0.6, 2.0).toDouble();
  return '''
  <script id="dictionary-host-text-scale">
    (() => {
      const markerAttribute = 'data-lumalex-text-scale-base';
      const originalFontSizeAttribute =
        'data-lumalex-original-font-size';
      const originalFontSizePriorityAttribute =
        'data-lumalex-original-font-size-priority';
      const originalLineHeightAttribute =
        'data-lumalex-original-line-height';
      const originalLineHeightPriorityAttribute =
        'data-lumalex-original-line-height-priority';
      const hostUiSelector = '[data-lumalex-host-ui]';
      const updateClass = 'lumalex-text-scale-updating';
      const state = {
        scale: 1,
        updateQueued: false,
      };

      const restoreProperty = (element, name, value, priority) => {
        if (value) {
          element.style.setProperty(name, value, priority);
        } else {
          element.style.removeProperty(name);
        }
      };

      const rememberOriginalStyle = (element) => {
        if (element.hasAttribute(markerAttribute)) return;
        element.setAttribute(markerAttribute, '1');
        element.setAttribute(
          originalFontSizeAttribute,
          element.style.getPropertyValue('font-size')
        );
        element.setAttribute(
          originalFontSizePriorityAttribute,
          element.style.getPropertyPriority('font-size')
        );
        element.setAttribute(
          originalLineHeightAttribute,
          element.style.getPropertyValue('line-height')
        );
        element.setAttribute(
          originalLineHeightPriorityAttribute,
          element.style.getPropertyPriority('line-height')
        );
      };

      const scaledTextElements = () => {
        if (!document.body) return [];
        const elements = Array.from(
          document.body.querySelectorAll('[' + markerAttribute + ']')
        );
        if (document.body.hasAttribute(markerAttribute)) {
          elements.unshift(document.body);
        }
        return elements;
      };

      const restorePublisherStyles = () => {
        for (const element of scaledTextElements()) {
          restoreProperty(
            element,
            'font-size',
            element.getAttribute(originalFontSizeAttribute) || '',
            element.getAttribute(originalFontSizePriorityAttribute) || ''
          );
          restoreProperty(
            element,
            'line-height',
            element.getAttribute(originalLineHeightAttribute) || '',
            element.getAttribute(originalLineHeightPriorityAttribute) || ''
          );
        }
      };

      const releaseTrackedElements = () => {
        for (const element of scaledTextElements()) {
          element.removeAttribute(markerAttribute);
          element.removeAttribute(originalFontSizeAttribute);
          element.removeAttribute(originalFontSizePriorityAttribute);
          element.removeAttribute(originalLineHeightAttribute);
          element.removeAttribute(originalLineHeightPriorityAttribute);
        }
      };

      const visibleTextElements = () => {
        if (!document.body) return [];
        return [document.body, ...document.body.querySelectorAll('*')]
          .filter((element) =>
            element.style &&
            !element.closest(hostUiSelector) &&
            !element.matches(
              'script, style, link, meta, base, title, template, noscript'
            )
          );
      };

      const setTextScale = (requestedScale) => {
        const numericScale = Number(requestedScale);
        const nextScale = Number.isFinite(numericScale)
          ? Math.min(2, Math.max(0.6, numericScale))
          : 1;
        state.scale = nextScale;
        const root = document.documentElement;
        root.classList.add(updateClass);

        try {
          // Always return to the publisher's own CSS before measuring. Store
          // those original declarations on the element itself: Collins and
          // similar dictionaries clone or replace link nodes, and attributes
          // travel with a clone while WeakMap entries do not.
          restorePublisherStyles();

          // Collins declares `transition: all 1s` on SYN links. Without a
          // transition-free layout flush, getComputedStyle() reports an
          // animated intermediate font size after restoration; multiplying
          // that value makes the link grow again on every update.
          if (document.body) void document.body.offsetHeight;

          // At the default size there is nothing to measure. In particular,
          // do not annotate every element of a large entry: an ODE_2024
          // article may contain tens of thousands of nodes.
          if (Math.abs(nextScale - 1) < 0.001) {
            releaseTrackedElements();
            return;
          }
          const snapshots = [];
          for (const element of visibleTextElements()) {
            rememberOriginalStyle(element);
            const computed = getComputedStyle(element);
            const fontSize = Number.parseFloat(computed.fontSize);
            const lineHeight = Number.parseFloat(computed.lineHeight);
            snapshots.push({element, fontSize, lineHeight});
          }

          for (const snapshot of snapshots) {
            if (Number.isFinite(snapshot.fontSize) && snapshot.fontSize > 0) {
              snapshot.element.style.setProperty(
                'font-size',
                `\${snapshot.fontSize * nextScale}px`,
                'important'
              );
            }
            if (Number.isFinite(snapshot.lineHeight) && snapshot.lineHeight > 0) {
              snapshot.element.style.setProperty(
                'line-height',
                `\${snapshot.lineHeight * nextScale}px`,
                'important'
              );
            }
          }

          // Commit the final sizes while transitions are still disabled.
          if (document.body) void document.body.offsetHeight;
        } finally {
          root.classList.remove(updateClass);
        }
      };

      const queueRefresh = () => {
        if (state.updateQueued) return;
        state.updateQueued = true;
        requestAnimationFrame(() => {
          state.updateQueued = false;
          setTextScale(state.scale);
        });
      };

      document.documentElement.style.setProperty(
        '-webkit-text-size-adjust',
        'none',
        'important'
      );
      document.documentElement.style.setProperty(
        'text-size-adjust',
        'none',
        'important'
      );
      window.__lumalexSetTextScale = setTextScale;
      setTextScale($scale);

      // Some dictionaries reveal or insert senses after their own script has
      // loaded. Re-measure inserted nodes at the publisher's base size. Class
      // changes do not require a refresh because the initial pass already
      // includes hidden nodes; observing them would turn a continuous Android
      // floating-window resize into repeated font multiplication.
      if (document.body && typeof MutationObserver === 'function') {
        const belongsToHostUi = (node) => {
          const element = node instanceof Element ? node : node.parentElement;
          return Boolean(
            element &&
            (element.matches(hostUiSelector) || element.closest(hostUiSelector))
          );
        };
        new MutationObserver((records) => {
          const publisherContentChanged = records.some((record) =>
            [...record.addedNodes, ...record.removedNodes]
              .some((node) => !belongsToHostUi(node))
          );
          if (publisherContentChanged) queueRefresh();
        }).observe(document.body, {
          subtree: true,
          childList: true
        });
      }
      window.addEventListener('load', queueRefresh, {once: true});
    })();
  </script>''';
}

/// Wraps dictionary markup in a local-origin document.
String buildArticleDocument(
  String articleHtml, {
  required bool localScriptCompatibilityEnabled,
  String resourceBaseUrl = 'http://127.0.0.1/dictionary/test-session/resource/',
  bool includeNativeBridges = true,
  bool includeWindowsSelectionMenu = false,
  double textScale = 1,
}) {
  final scriptPolicy = localScriptCompatibilityEnabled
      ? "'self' 'unsafe-inline' 'unsafe-eval' blob:"
      : "'none'";
  final visibilityFallback = localScriptCompatibilityEnabled
      ? ''
      : '''
  <style>
    /* In safe mode dictionary scripts cannot reveal script-hidden entries. */
    .oald { display: block !important; }
  </style>''';
  final publisherDefaults = localScriptCompatibilityEnabled
      ? _publisherPresentationDefaults(articleHtml)
      : '';
  final initialTextScale = textScale.clamp(0.6, 2.0);
  final textScaleBootstrap = localScriptCompatibilityEnabled
      ? _textScaleBootstrap(initialTextScale.toDouble())
      : '';
  return '''<!doctype html>
<html style="-webkit-text-size-adjust: none; text-size-adjust: none">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light only">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; base-uri 'self'; connect-src 'self'; font-src 'self' data:; form-action 'none'; frame-src 'none'; img-src 'self' data: blob:; media-src 'self' data: blob: sound:; object-src 'none'; script-src $scriptPolicy; style-src 'self' 'unsafe-inline'">
  <meta name="referrer" content="no-referrer">
  <base href="$resourceBaseUrl">
  <style id="dictionary-host-theme">
    html, body {
      color-scheme: only light;
      background-color: #fff;
    }
    html, body, body * {
      -webkit-text-size-adjust: none !important;
      text-size-adjust: none !important;
    }
    html.lumalex-text-scale-updating body,
    html.lumalex-text-scale-updating body * {
      transition: none !important;
      animation: none !important;
    }
  </style>
  ${localScriptCompatibilityEnabled ? _lightColorSchemeBootstrap : ''}
  ${localScriptCompatibilityEnabled && includeNativeBridges ? _localSoundBridge : ''}
  ${localScriptCompatibilityEnabled && includeNativeBridges ? _doubleClickLookupBridge : ''}
  ${localScriptCompatibilityEnabled && includeNativeBridges ? _selectionChangeBridge : ''}
  ${localScriptCompatibilityEnabled && includeNativeBridges && includeWindowsSelectionMenu ? _windowsSelectionContextMenuBridge : ''}
  $publisherDefaults
</head>
<body class="lumalex-article">
$articleHtml
$visibilityFallback
$textScaleBootstrap
</body>
</html>''';
}

@visibleForTesting
String buildSafeArticleDocument(String articleHtml) => buildArticleDocument(
      articleHtml,
      localScriptCompatibilityEnabled: false,
    );

String? doubleClickLookupHeadwordForTesting(Object? rawValue) {
  if (rawValue is! String) {
    return null;
  }
  final value = rawValue.trim();
  if (value.isEmpty || value.length > 128 || value.contains(RegExp(r'\s'))) {
    return null;
  }
  return value;
}
