import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:just_audio/just_audio.dart';

import '../models/article.dart';
import '../services/dictionary_content_server.dart';
import '../services/dictionary_engine.dart';
import '../services/dictionary_text_to_speech.dart';
import 'article_page.dart';

const _maximumAggregateResourceBytes = 20 * 1024 * 1024;
const _aggregateSoundHandler = 'aggregateDictionarySound';
const _aggregateTtsHandler = 'aggregateDictionaryTextToSpeech';
const _aggregateLinkHandler = 'aggregateDictionaryLink';
const _aggregateWordHandler = 'aggregateDictionaryWord';
const _aggregateActiveHandler = 'aggregateActiveDictionary';
const _aggregateReadingScrollHandler = 'aggregateDictionaryReadingScroll';
const _aggregateSelectionHandler = 'aggregateDictionarySelection';
const _aggregateSelectionActionHandler = 'aggregateDictionarySelectionAction';
const _copySelectionContextMenuItemId = 2000;
const _lookupSelectionContextMenuItemId = 2001;
const _windowsAudioLoadStabilizationDelay = Duration(milliseconds: 80);

enum AggregateArticlePresentation {
  continuous,
  selectedDictionary,
}

enum _AggregateWindowsSelectionMenuAction { copy, lookup }

String aggregateArticlePresentationCss(
  AggregateArticlePresentation presentation,
) =>
    presentation == AggregateArticlePresentation.selectedDictionary
        ? '''
  body.selected-dictionary .dictionary-section { display: none; margin: 0; border: 0; border-radius: 0; }
  body.selected-dictionary .dictionary-section.active { display: block; }
  body.selected-dictionary .dictionary-header { display: none; }
'''
        : '';

String aggregateDictionarySelectionJavascript() => '''
  const selectedDictionaryMode =
    document.body.classList.contains('selected-dictionary');
  const dictionaryScrollOffsets = new Map();
  window.__lumalexShowDictionary = (domId, requestedOffset) => {
    if (!selectedDictionaryMode) return false;
    const next = document.getElementById(domId);
    if (!next) return false;
    const current = document.querySelector('.dictionary-section.active');
    if (current && current !== next) {
      dictionaryScrollOffsets.set(current.id, window.scrollY || 0);
      current.classList.remove('active');
    }
    next.classList.add('active');
    const frame = next.querySelector('iframe');
    if (frame && typeof frame.__lumalexResize === 'function') {
      frame.__lumalexResize();
      setTimeout(frame.__lumalexResize, 80);
      setTimeout(frame.__lumalexResize, 280);
    }
    const remembered = dictionaryScrollOffsets.get(domId) || 0;
    const requested = Number(requestedOffset);
    const destination = Number.isFinite(requested) ? requested : remembered;
    requestAnimationFrame(() => {
      window.scrollTo({top: Math.max(0, destination), behavior: 'auto'});
      const token = next.dataset.token;
      if (token) bridge.callHandler('$_aggregateActiveHandler', token);
    });
    return true;
  };
''';

String aggregateDictionarySelectionObserverJavascript() => '''
    let selectionReportTimer = 0;
    const reportDictionarySelection = () => {
      selectionReportTimer = 0;
      const selected = String(doc.getSelection() || '').trim();
      if (selected) {
        bridge.callHandler('$_aggregateSelectionHandler', token, selected);
      }
    };
    const queueDictionarySelectionReport = () => {
      clearTimeout(selectionReportTimer);
      selectionReportTimer = setTimeout(reportDictionarySelection, 0);
    };
    doc.addEventListener('selectionchange', queueDictionarySelectionReport);
    doc.addEventListener('pointerup', queueDictionarySelectionReport, true);
    doc.addEventListener('touchend', queueDictionarySelectionReport, true);
    doc.addEventListener('contextmenu', queueDictionarySelectionReport, true);
''';

String aggregateWindowsSelectionContextMenuJavascript() => r'''
    let lumalexSelectionMenu = null;
    const closeLumalexSelectionMenu = () => {
      if (lumalexSelectionMenu) lumalexSelectionMenu.remove();
      lumalexSelectionMenu = null;
    };
    const makeLumalexSelectionButton = (label, action, selected) => {
      const button = doc.createElement('button');
      button.type = 'button';
      button.textContent = label;
      button.style.cssText = [
        'min-width:72px', 'min-height:44px', 'padding:0 16px',
        'border:0', 'background:transparent', 'color:#fff',
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
          const lookupUrl = new URL(
            '/__lumalex_selection_lookup__', window.location.href
          );
          lookupUrl.searchParams.set('token', token);
          lookupUrl.searchParams.set('text', selected);
          window.location.assign(lookupUrl.href);
          closeLumalexSelectionMenu();
          return;
        }
        try {
          await bridge.callHandler(
            'aggregateDictionarySelectionAction', token, action, selected
          );
        } finally {
          closeLumalexSelectionMenu();
        }
      };
      // Dispatch before the WebView can collapse the selection or transfer
      // focus. The click listener remains as the keyboard-accessible path.
      button.addEventListener('pointerdown', dispatch);
      button.addEventListener('click', dispatch);
      return button;
    };
    doc.addEventListener('contextmenu', (event) => {
      const selected = String(doc.getSelection() || '').trim();
      if (!selected) {
        closeLumalexSelectionMenu();
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      closeLumalexSelectionMenu();
      lumalexSelectionMenu = doc.createElement('div');
      lumalexSelectionMenu.setAttribute('role', 'menu');
      lumalexSelectionMenu.style.cssText = [
        'position:fixed', 'display:flex', 'z-index:2147483647',
        'overflow:hidden', 'border-radius:10px', 'background:#263232',
        'box-shadow:0 8px 24px rgba(0,0,0,.28)', 'user-select:none'
      ].join(';');
      lumalexSelectionMenu.appendChild(
        makeLumalexSelectionButton('复制', 'copy', selected)
      );
      const divider = doc.createElement('span');
      divider.style.cssText =
        'width:1px;background:rgba(255,255,255,.22);margin:8px 0';
      lumalexSelectionMenu.appendChild(divider);
      lumalexSelectionMenu.appendChild(
        makeLumalexSelectionButton('查词', 'lookup', selected)
      );
      doc.body.appendChild(lumalexSelectionMenu);
      const bounds = lumalexSelectionMenu.getBoundingClientRect();
      const view = doc.defaultView;
      const left = Math.max(
        8,
        Math.min(event.clientX, view.innerWidth - bounds.width - 8)
      );
      const top = Math.max(
        8,
        Math.min(event.clientY, view.innerHeight - bounds.height - 8)
      );
      lumalexSelectionMenu.style.left = `${left}px`;
      lumalexSelectionMenu.style.top = `${top}px`;
    }, true);
    doc.addEventListener('pointerdown', (event) => {
      if (lumalexSelectionMenu &&
          !lumalexSelectionMenu.contains(event.target)) {
        closeLumalexSelectionMenu();
      }
    }, true);
    doc.addEventListener('scroll', closeLumalexSelectionMenu, true);
    doc.defaultView.addEventListener('blur', closeLumalexSelectionMenu);
''';

class AggregateArticleSection {
  const AggregateArticleSection({
    required this.title,
    required this.article,
    required this.textScale,
  });

  final String title;
  final Article article;
  final double textScale;
}

class AggregateArticlePageController {
  _AggregateArticlePageState? _state;

  Future<bool> scrollToDictionary(String mdxPath) {
    final state = _state;
    return state == null
        ? Future.value(false)
        : state._scrollToDictionary(mdxPath);
  }

  Future<bool> showDictionary(String mdxPath) => scrollToDictionary(mdxPath);

  Future<void> updateDictionaryTitle(String mdxPath, String title) async =>
      _state?._updateDictionaryTitle(mdxPath, title);

  Future<double> readScrollOffset() async =>
      await _state?._readScrollOffset() ?? 0;

  Future<void> stopPlayback() async => _state?._stopPlayback();

  void _attach(_AggregateArticlePageState state) => _state = state;

  void _detach(_AggregateArticlePageState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// Hosts all matching dictionaries inside one WebView. Each dictionary keeps
/// its own iframe/document so publisher CSS and scripts remain isolated, while
/// the parent document provides one reliable native scrolling surface.
class AggregateArticlePage extends StatefulWidget {
  const AggregateArticlePage({
    required this.sections,
    required this.engine,
    required this.controller,
    required this.onOpenHeadword,
    this.initialScrollOffset,
    this.initialMdxPath,
    this.initialAnchor,
    this.onActiveDictionaryChanged,
    this.onReadingScroll,
    this.presentation = AggregateArticlePresentation.continuous,
    super.key,
  });

  final List<AggregateArticleSection> sections;
  final DictionaryEngine engine;
  final AggregateArticlePageController controller;
  final double? initialScrollOffset;
  final String? initialMdxPath;
  final String? initialAnchor;
  final ValueChanged<String>? onActiveDictionaryChanged;
  final VoidCallback? onReadingScroll;
  final AggregateArticlePresentation presentation;
  final Future<void> Function(
    String mdxPath,
    String headword,
    String? anchor,
    double sourceScrollOffset,
  ) onOpenHeadword;

  @override
  State<AggregateArticlePage> createState() => _AggregateArticlePageState();
}

class _AggregateArticlePageState extends State<AggregateArticlePage> {
  InAppWebViewController? _webViewController;
  DictionaryContentSession? _hostSession;
  final Map<String, DictionaryContentSession> _childSessions = {};
  final Map<String, AggregateArticleSection> _sectionByToken = {};
  final Map<String, String> _domIdByMdxPath = {};
  AudioPlayer? _audioPlayer;
  final _textToSpeech = DictionaryTextToSpeech();
  Directory? _activeAudioDirectory;
  int _loadGeneration = 0;
  int _audioGeneration = 0;
  bool _loading = true;
  String? _error;
  String? _selectedText;
  String? _selectedToken;
  bool _isShowingWindowsSelectionMenu = false;
  final _readerSurfaceKey = GlobalKey();
  late final ContextMenu _selectionContextMenu;

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
    _selectionContextMenu = ContextMenu(
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      menuItems: [
        ContextMenuItem(
          id: _copySelectionContextMenuItemId,
          title: '复制',
          action: _copySelectedText,
        ),
        ContextMenuItem(
          id: _lookupSelectionContextMenuItemId,
          title: '查词',
          action: _lookupSelectedText,
        ),
      ],
      onCreateContextMenu: (_) async {
        final selection = await _readCurrentSelection(includeCached: false);
        if (selection != null) {
          _selectedText = selection.text;
          _selectedToken = selection.token;
        }
      },
    );
  }

  @override
  void didUpdateWidget(covariant AggregateArticlePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
    if (_documentSignature(widget.sections) !=
        _documentSignature(oldWidget.sections)) {
      final controller = _webViewController;
      if (controller != null) unawaited(_loadDocument(controller));
    } else {
      final controller = _webViewController;
      final selectedPath = widget.initialMdxPath;
      if (controller != null &&
          widget.presentation ==
              AggregateArticlePresentation.selectedDictionary &&
          selectedPath != null &&
          selectedPath != oldWidget.initialMdxPath) {
        unawaited(_scrollToDictionary(selectedPath));
      }
      if (_changedTextScales(widget.sections, oldWidget.sections)
          case final changedScales when changedScales.isNotEmpty) {
        if (controller != null) {
          unawaited(_applyTextScales(controller, changedScales));
        }
      }
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _audioGeneration++;
    widget.controller._detach(this);
    _closeSessions();
    final player = _audioPlayer;
    if (player != null) unawaited(player.dispose());
    unawaited(_textToSpeech.stop());
    unawaited(_removeAudioDirectory());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            key: _readerSurfaceKey,
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _handlePointerSignal,
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                allowContentAccess: false,
                allowFileAccess: false,
                blockNetworkLoads: false,
                cacheEnabled: true,
                disableContextMenu: Platform.isIOS || Platform.isWindows,
                incognito: false,
                javaScriptCanOpenWindowsAutomatically: false,
                javaScriptEnabled: true,
                builtInZoomControls: false,
                displayZoomControls: false,
                layoutAlgorithm: LayoutAlgorithm.NORMAL,
                mediaPlaybackRequiresUserGesture: true,
                resourceCustomSchemes: const ['dictres', 'sound'],
                supportZoom: false,
                supportMultipleWindows: false,
                textZoom: 100,
                useShouldOverrideUrlLoading: true,
                useWideViewPort: false,
              ),
              contextMenu: Platform.isIOS || Platform.isWindows
                  ? null
                  : _selectionContextMenu,
              onWebViewCreated: (controller) {
                _webViewController = controller;
                if (!Platform.isIOS && !Platform.isWindows) {
                  unawaited(controller.setContextMenu(_selectionContextMenu));
                }
                _registerHandlers(controller);
                unawaited(_loadDocument(controller));
              },
              shouldOverrideUrlLoading: _handleNavigation,
              onLoadStop: (controller, url) async {
                final uri = url?.uriValue;
                if (uri == null || !(_hostSession?.owns(uri) ?? false)) return;
                if (!mounted) return;
                setState(() {
                  _loading = false;
                  _error = null;
                });
                final offset = widget.initialScrollOffset;
                final selectedPath = widget.initialMdxPath;
                final anchor = widget.initialAnchor;
                if (widget.presentation ==
                        AggregateArticlePresentation.selectedDictionary &&
                    selectedPath != null) {
                  await _scrollToDictionary(
                    selectedPath,
                    requestedOffset: offset,
                  );
                  if ((offset == null || offset <= 0) && anchor != null) {
                    await _scrollToAnchor(selectedPath, anchor);
                  }
                } else if (offset != null && offset > 0) {
                  await controller.evaluateJavascript(
                    source:
                        'window.scrollTo(0, ${offset.clamp(0, double.maxFinite)});',
                  );
                } else if (widget.initialMdxPath != null &&
                    widget.initialAnchor != null) {
                  await _scrollToAnchor(
                    widget.initialMdxPath!,
                    widget.initialAnchor!,
                  );
                }
              },
              onReceivedError: (_, request, error) {
                if (request.isForMainFrame == true && mounted) {
                  setState(() {
                    _loading = false;
                    _error = '综合词典页面加载失败：$error';
                  });
                }
              },
              onLoadResourceWithCustomScheme: (_, request) =>
                  _loadCustomResource(request),
            ),
          ),
          if (_loading)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: const Center(child: CircularProgressIndicator()),
            ),
          if (_error case final message?)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );

  Future<void> _handleWindowsSelectionMenuRequest(
    List<dynamic> arguments,
  ) async {
    if (!Platform.isWindows || arguments.isEmpty) return;
    final rawText = arguments[0];
    if (rawText is! String || rawText.trim().isEmpty) return;
    final rawFrameUri = arguments.elementAtOrNull(1);
    final frameUri = rawFrameUri is String ? Uri.tryParse(rawFrameUri) : null;
    String? token;
    if (frameUri != null) {
      for (final entry in _childSessions.entries) {
        if (entry.value.owns(frameUri)) {
          token = entry.key;
          break;
        }
      }
    }
    token ??= _activeDictionaryToken();
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
      debugPrint('Aggregate Windows focus release failed: $error');
    }
    if (!mounted) return;
    unawaited(
      _showWindowsSelectionMenu(
        renderBox.localToGlobal(localPosition),
        initialSelection: (text: rawText.trim(), token: token),
      ),
    );
  }

  Future<void> _showWindowsSelectionMenu(
    Offset globalPosition, {
    ({String text, String? token})? initialSelection,
  }) async {
    _isShowingWindowsSelectionMenu = true;
    try {
      final selection = initialSelection ?? await _readCurrentSelection();
      if (!mounted || selection == null) return;
      _selectedText = selection.text;
      _selectedToken = selection.token;
      final overlay = Overlay.of(context).context.findRenderObject();
      if (overlay is! RenderBox) return;
      final localPosition = overlay.globalToLocal(globalPosition);
      final x = localPosition.dx.clamp(0.0, overlay.size.width).toDouble();
      final y = localPosition.dy.clamp(0.0, overlay.size.height).toDouble();
      final action = await showMenu<_AggregateWindowsSelectionMenuAction>(
        context: context,
        position: RelativeRect.fromLTRB(
          x,
          y,
          overlay.size.width - x,
          overlay.size.height - y,
        ),
        items: const [
          PopupMenuItem(
            value: _AggregateWindowsSelectionMenuAction.copy,
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
            value: _AggregateWindowsSelectionMenuAction.lookup,
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
      switch (action) {
        case _AggregateWindowsSelectionMenuAction.copy:
          await Clipboard.setData(ClipboardData(text: selection.text));
          _selectedText = null;
          _selectedToken = null;
          _showSelectionMessage('已复制');
        case _AggregateWindowsSelectionMenuAction.lookup:
          final headword = doubleClickLookupHeadwordForTesting(selection.text);
          final token = selection.token ?? _activeDictionaryToken();
          if (headword == null) {
            _showSelectionMessage('请选择一个单词后再查词。');
            return;
          }
          if (token == null) return;
          _selectedText = null;
          _selectedToken = null;
          await _openHeadword(token, headword, null);
      }
    } catch (error) {
      debugPrint('Aggregate Windows selection menu failed: $error');
    } finally {
      _isShowingWindowsSelectionMenu = false;
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final controller = _webViewController;
      if (controller == null) return;
      final dx = event.scrollDelta.dx;
      final dy = event.scrollDelta.dy;
      unawaited(
        controller.evaluateJavascript(
          source: 'window.scrollBy(${dx.toString()}, ${dy.toString()});',
        ),
      );
    });
  }

  void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: _aggregateSoundHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final rawUri = arguments.elementAtOrNull(1);
        if (token is String && rawUri is String) {
          unawaited(_playSound(token, rawUri));
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateTtsHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final text = arguments.elementAtOrNull(1);
        final locale = arguments.elementAtOrNull(2);
        if (token is String &&
            _sectionByToken.containsKey(token) &&
            text is String &&
            locale is String) {
          unawaited(_speakExample(text, locale));
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateLinkHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final rawUrl = arguments.elementAtOrNull(1);
        if (token is String && rawUrl is String) {
          unawaited(_openLink(token, rawUrl));
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateWordHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final rawWord = arguments.elementAtOrNull(1);
        final word = doubleClickLookupHeadwordForTesting(rawWord);
        if (token is String && word != null) {
          unawaited(_openHeadword(token, word, null));
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateActiveHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final section = token is String ? _sectionByToken[token] : null;
        if (section != null) {
          widget.onActiveDictionaryChanged?.call(section.article.mdxPath);
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateReadingScrollHandler,
      callback: (_) {
        widget.onReadingScroll?.call();
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateSelectionHandler,
      callback: (arguments) {
        final token = arguments.firstOrNull;
        final selected = arguments.elementAtOrNull(1);
        if (token is String &&
            _sectionByToken.containsKey(token) &&
            selected is String &&
            selected.trim().isNotEmpty) {
          _selectedToken = token;
          _selectedText = selected.trim();
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: _aggregateSelectionActionHandler,
      callback: _handleWindowsSelectionAction,
    );
    controller.addJavaScriptHandler(
      handlerName: windowsSelectionMenuRequestedHandlerName,
      callback: _handleWindowsSelectionMenuRequest,
    );
  }

  Future<void> _loadDocument(InAppWebViewController controller) async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    _closeSessions();
    final sections = widget.sections;
    if (sections.isEmpty) return;
    try {
      final records = <({
        AggregateArticleSection section,
        DictionaryContentSession session,
        String domId,
      })>[];
      for (var index = 0; index < sections.length; index++) {
        final section = sections[index];
        final session = await DictionaryContentServer.instance.openSession(
          engine: widget.engine,
          mdxPath: section.article.mdxPath,
        );
        if (!mounted || generation != _loadGeneration) {
          session.close();
          return;
        }
        session.setDocument(
          buildArticleDocument(
            section.article.html,
            localScriptCompatibilityEnabled: true,
            resourceBaseUrl: session.resourceBaseUri.toString(),
            includeNativeBridges: false,
            textScale: section.textScale,
          ),
        );
        final domId = 'dictionary-section-$index';
        _childSessions[session.token] = session;
        _sectionByToken[session.token] = section;
        _domIdByMdxPath[section.article.mdxPath] = domId;
        records.add((section: section, session: session, domId: domId));
      }
      final host = await DictionaryContentServer.instance.openSession(
        engine: widget.engine,
        mdxPath: sections.first.article.mdxPath,
      );
      if (!mounted || generation != _loadGeneration) {
        host.close();
        return;
      }
      _hostSession = host;
      host.setDocument(_buildAggregateDocument(records));
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(host.articleUri.toString())),
      );
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loading = false;
          _error = '无法建立综合词典页面：$error';
        });
      }
    }
  }

  String _buildAggregateDocument(
    List<
            ({
              AggregateArticleSection section,
              DictionaryContentSession session,
              String domId,
            })>
        records,
  ) {
    final requestedPath = widget.initialMdxPath;
    final selectedPath = records
            .where(
              (record) => record.section.article.mdxPath == requestedPath,
            )
            .map((record) => record.section.article.mdxPath)
            .firstOrNull ??
        records.first.section.article.mdxPath;
    final selectedMode =
        widget.presentation == AggregateArticlePresentation.selectedDictionary;
    final bodyClass = selectedMode ? ' class="selected-dictionary"' : '';
    final sections = records.map((record) {
      final title = const HtmlEscape(HtmlEscapeMode.element)
          .convert(record.section.title);
      final token = const HtmlEscape(HtmlEscapeMode.attribute)
          .convert(record.session.token);
      final src = const HtmlEscape(HtmlEscapeMode.attribute)
          .convert(record.session.articleUri.toString());
      final activeClass =
          selectedMode && record.section.article.mdxPath == selectedPath
              ? ' active'
              : '';
      return '''
<section class="dictionary-section$activeClass" id="${record.domId}" data-token="$token">
  <button class="dictionary-header" type="button" aria-expanded="true">
    <span class="book">▣</span><span class="title">$title</span>
    <span class="count">1 条</span><span class="chevron">⌃</span>
  </button>
  <iframe data-token="$token" data-scale="${record.section.textScale}" src="$src" scrolling="no"></iframe>
</section>''';
    }).join('\n');
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="color-scheme" content="light only">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; frame-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'">
<style>
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #f8fafa; color: #172323; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  .dictionary-section { margin: 0 0 12px; background: #fff; border: 1px solid #d5e0e0; border-radius: 16px; overflow: hidden; }
  .dictionary-header { width: 100%; min-height: 52px; display: flex; align-items: center; gap: 10px; border: 0; border-bottom: 1px solid #d5e0e0; padding: 0 16px; background: #fff; color: #172323; font: inherit; cursor: pointer; text-align: left; }
  .dictionary-header:hover { background: #f2f6f6; }
  .book { color: #087e87; font-size: 18px; }
  .title { min-width: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 700; }
  .count { color: #607171; font-size: 13px; }
  .chevron { font-size: 18px; transition: transform .16s ease; }
  .dictionary-section.collapsed .chevron { transform: rotate(180deg); }
  iframe { width: 100%; height: 1px; display: block; border: 0; background: #fff; touch-action: pan-y; }
  .dictionary-section.collapsed iframe { display: none; }
  ${aggregateArticlePresentationCss(widget.presentation)}
</style></head><body$bodyClass>
$sections
<script>
(() => {
  const bridge = window.flutter_inappwebview;
  ${dictionaryTextToSpeechResolverJavascript()}
  const ignored = 'a,button,input,select,textarea,[role="button"],[contenteditable="true"],.sound,.speaker,.senseButton,.cdepe-nav,.cdepe-nav-dict,.cdepe-nav-sense,.maldpe-nav';
  const sections = Array.from(document.querySelectorAll('.dictionary-section'));
  ${aggregateDictionarySelectionJavascript()}
  let activeReportQueued = false;
  const reportActiveDictionary = () => {
    activeReportQueued = false;
    if (selectedDictionaryMode) {
      const active = document.querySelector('.dictionary-section.active');
      if (active) bridge.callHandler('$_aggregateActiveHandler', active.dataset.token);
      return;
    }
    const targetY = Math.max(0, window.innerHeight * 0.18);
    const visible = sections
      .filter(section => !section.classList.contains('collapsed'))
      .map(section => ({section, rect: section.getBoundingClientRect()}))
      .filter(({rect}) => rect.bottom > 0 && rect.top < window.innerHeight);
    if (!visible.length) return;
    const pastTarget = visible.filter(({rect}) => rect.top <= targetY);
    const active = (pastTarget.length ? pastTarget : visible)
      .sort((left, right) => {
        if (pastTarget.length) return right.rect.top - left.rect.top;
        return Math.abs(left.rect.top - targetY) -
          Math.abs(right.rect.top - targetY);
      })[0];
    if (active) bridge.callHandler('$_aggregateActiveHandler', active.section.dataset.token);
  };
  const queueActiveDictionaryReport = () => {
    if (activeReportQueued) return;
    activeReportQueued = true;
    requestAnimationFrame(reportActiveDictionary);
  };
  window.addEventListener('scroll', queueActiveDictionaryReport, {passive: true});
  window.addEventListener('resize', queueActiveDictionaryReport, {passive: true});
  let previousReadingOffset = window.scrollY || 0;
  let lastReadingSentAt = 0;
  window.addEventListener('scroll', () => {
    const offset = window.scrollY || document.documentElement.scrollTop || 0;
    if (Math.abs(offset - previousReadingOffset) < 14) return;
    previousReadingOffset = offset;
    const now = Date.now();
    if (now - lastReadingSentAt < 240) return;
    lastReadingSentAt = now;
    bridge.callHandler('$_aggregateReadingScrollHandler', offset);
  }, {passive: true});
  const setupFrame = (frame) => {
    const token = frame.dataset.token;
    const doc = frame.contentDocument;
    if (!doc || !doc.body || frame.dataset.ready === '1') return;
    frame.dataset.ready = '1';
    doc.documentElement.style.setProperty('height', 'auto', 'important');
    doc.documentElement.style.setProperty('min-height', '0', 'important');
    // The iframe is sized to the full article, so its root must never create a
    // second scrolling viewport. Otherwise WebKit traps the trackpad at the
    // end of the current dictionary instead of continuing the aggregate page.
    doc.documentElement.style.setProperty('overflow-y', 'hidden', 'important');
    doc.documentElement.style.setProperty('touch-action', 'pan-y', 'important');
    doc.body.style.setProperty('height', 'auto', 'important');
    doc.body.style.setProperty('min-height', '0', 'important');
    doc.body.style.setProperty('overflow-y', 'visible', 'important');
    doc.body.style.setProperty('touch-action', 'pan-y', 'important');
    if (typeof doc.defaultView.__lumalexSetTextScale === 'function') {
      doc.defaultView.__lumalexSetTextScale(frame.dataset.scale || 1);
    }
    let resizing = false;
    let resizeQueued = false;
    const resize = () => {
      const owner = frame.closest('.dictionary-section');
      if (owner && owner.classList.contains('collapsed')) return;
      if (selectedDictionaryMode &&
          owner && !owner.classList.contains('active')) return;
      if (resizing) {
        resizeQueued = true;
        return;
      }
      resizing = true;
      if (frame.dataset.measured !== '1') {
        frame.dataset.measured = '1';
        frame.style.height = '1px';
      }
      requestAnimationFrame(() => {
        // Publisher packages sometimes put the whole article in their own
        // fixed-height scrolling container. Expand those containers so the
        // aggregate document, rather than an individual dictionary, owns the
        // vertical scroll range.
        for (const element of doc.body.querySelectorAll('*')) {
          const style = doc.defaultView.getComputedStyle(element);
          const overflowY = style.overflowY;
          if ((overflowY === 'auto' || overflowY === 'scroll') &&
              element.scrollHeight > element.clientHeight + 2 &&
              element.dataset.lumalexOverflowExpanded !== '1') {
            element.dataset.lumalexOverflowExpanded = '1';
            element.style.setProperty('height', 'auto', 'important');
            element.style.setProperty('max-height', 'none', 'important');
            element.style.setProperty('overflow-y', 'visible', 'important');
          }
        }
        const scrollTop = doc.defaultView.scrollY || 0;
        // Never use the root element here: its client/scroll height inherits
        // the iframe's previous height, which would make the measurement
        // grow-only. The body and visible descendants describe the real
        // article and can shrink again after an expanded panel is closed.
        let contentBottom = Math.max(doc.body.scrollHeight, 80);
        const includeRect = (element, rect) => {
          if (!rect || (!rect.width && !rect.height)) return;
          let visibleTop = rect.top;
          let visibleBottom = rect.bottom;
          let ancestor = element ? element.parentElement : null;
          while (ancestor && ancestor !== doc.documentElement) {
            const ancestorStyle = doc.defaultView.getComputedStyle(ancestor);
            if (ancestorStyle.display === 'none' ||
                ancestorStyle.visibility === 'hidden') return;
            if (ancestorStyle.overflowY === 'hidden' ||
                ancestorStyle.overflowY === 'clip') {
              const ancestorRect = ancestor.getBoundingClientRect();
              visibleTop = Math.max(visibleTop, ancestorRect.top);
              visibleBottom = Math.min(visibleBottom, ancestorRect.bottom);
              if (visibleBottom <= visibleTop) return;
            }
            ancestor = ancestor.parentElement;
          }
          contentBottom = Math.max(contentBottom, visibleBottom + scrollTop);
        };
        const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
        const range = doc.createRange();
        let textNode = walker.nextNode();
        while (textNode) {
          if (textNode.nodeValue && textNode.nodeValue.trim()) {
            const parent = textNode.parentElement;
            const style = parent ? doc.defaultView.getComputedStyle(parent) : null;
            if (!style || (style.display !== 'none' && style.visibility !== 'hidden')) {
              try {
                range.selectNodeContents(textNode);
                for (const rect of range.getClientRects()) includeRect(parent, rect);
              } catch (_) {}
            }
          }
          textNode = walker.nextNode();
        }
        range.detach();
        for (const element of [doc.body, ...doc.body.querySelectorAll('*')]) {
          const style = doc.defaultView.getComputedStyle(element);
          if (style.display === 'none' ||
              style.visibility === 'hidden' ||
              style.position === 'fixed') continue;
          const rect = element.getBoundingClientRect();
          includeRect(element, rect);
        }
        const bodyStyle = doc.defaultView.getComputedStyle(doc.body);
        const bottomSpacing =
          (parseFloat(bodyStyle.paddingBottom) || 0) +
          (parseFloat(bodyStyle.marginBottom) || 0) + 8;
        const height = Math.ceil(contentBottom + bottomSpacing);
        frame.style.height = Math.ceil(height) + 'px';
        queueActiveDictionaryReport();
        resizing = false;
        if (resizeQueued) {
          resizeQueued = false;
          requestAnimationFrame(resize);
        }
      });
    };
    frame.__lumalexResize = resize;
    const observer = new ResizeObserver(resize);
    observer.observe(doc.documentElement);
    observer.observe(doc.body);
    const mutationObserver = new MutationObserver(resize);
    mutationObserver.observe(doc.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ['class', 'style', 'hidden', 'open']
    });
    doc.addEventListener('load', resize, true);
    // Wheel and touch gestures originate inside the iframe, so WebKit would
    // otherwise trap them at the end of an individual dictionary. Forward
    // those gestures to the one aggregate scrolling document.
    const forwardWheel = (event) => {
      if (event.ctrlKey) return;
      const factor = event.deltaMode === 1
        ? 16
        : event.deltaMode === 2
          ? window.innerHeight
          : 1;
      event.preventDefault();
      event.stopImmediatePropagation();
      doc.defaultView.parent.scrollBy({
        left: event.deltaX * factor,
        top: event.deltaY * factor,
        behavior: 'auto'
      });
    };
    doc.defaultView.addEventListener(
      'wheel',
      forwardWheel,
      {capture: true, passive: false}
    );
    // WKWebView can consume a native trackpad gesture before dispatching a
    // JavaScript wheel event. Mirror any resulting subframe scroll back to the
    // aggregate page and immediately reset the subframe, so the gesture still
    // produces one continuous document.
    let forwardingScroll = false;
    const forwardSubframeScroll = (event) => {
      if (forwardingScroll) return;
      const target = event.target;
      const scrollingElement = target === doc
        ? doc.scrollingElement
        : target && typeof target.scrollTop === 'number'
          ? target
          : null;
      if (!scrollingElement) return;
      const top = scrollingElement.scrollTop || 0;
      if (!top) return;
      forwardingScroll = true;
      scrollingElement.scrollTop = 0;
      doc.defaultView.parent.scrollBy({top, behavior: 'auto'});
      requestAnimationFrame(() => { forwardingScroll = false; });
    };
    doc.addEventListener('scroll', forwardSubframeScroll, true);
    doc.defaultView.addEventListener('scroll', forwardSubframeScroll, true);
    // Do not synthesize touch scrolling here. Android WebView already has a
    // hardware-composited pan gesture for the aggregate document; forwarding
    // every inner-frame touchmove competed with it and caused visible lag and
    // reverse-direction jitter. The full-height frame has no own scroll range,
    // so `touch-action: pan-y` lets the native gesture chain to the parent.
    doc.addEventListener('click', (event) => {
      // `event.target` belongs to the iframe's JavaScript realm, so it is
      // not an `instanceof Element` from this parent document. Checking the
      // capability instead keeps an <a> target intact; otherwise a direct
      // click on Oxford's speaker link is mistaken for its parent and WebView
      // attempts to navigate to sound://..., which CSP correctly rejects.
      const rawTarget = event.target;
      const target = rawTarget && typeof rawTarget.closest === 'function'
        ? rawTarget
        : rawTarget && rawTarget.parentElement;
      // Publisher packages use several incompatible controls for examples
      // without local audio: OALD `.sound.tts`, Cambridge `audio_uk/audio_us`,
      // and Oxford Dictionaries 2024 `.sound-ai`. Resolve all of them to one
      // platform TTS request while keeping ordinary `sound:` links on MDD
      // recordings.
      const targetAtPointer = doc.elementFromPoint(event.clientX, event.clientY);
      const tts = (target && target.closest
        ? target.closest(lumalexDictionaryTtsSelector)
        : null) || (targetAtPointer && targetAtPointer.closest
          ? targetAtPointer.closest(lumalexDictionaryTtsSelector)
          : null);
      if (tts) {
        event.preventDefault(); event.stopImmediatePropagation();
        const request = lumalexDictionaryTtsRequest(tts);
        if (!request) return;
        bridge.callHandler(
          '$_aggregateTtsHandler',
          token,
          request.text,
          request.locale
        );
        return;
      }
      const link = target && target.closest ? target.closest('[href]') : null;
      const href = link ? link.getAttribute('href') : null;
      if (!href) return;
      if (/^sound:/i.test(href)) {
        event.preventDefault(); event.stopImmediatePropagation();
        bridge.callHandler('$_aggregateSoundHandler', token, href);
      } else if (/^(entry|bword|lookup|mdict|x-dictionary):/i.test(href)) {
        event.preventDefault(); event.stopImmediatePropagation();
        bridge.callHandler('$_aggregateLinkHandler', token, href);
      }
    }, true);
    doc.addEventListener('dblclick', (event) => {
      const rawTarget = event.target;
      const target = rawTarget && typeof rawTarget.closest === 'function'
        ? rawTarget
        : rawTarget && rawTarget.parentElement;
      if (!target || target.closest(ignored)) return;
      setTimeout(() => {
        const selected = String(doc.getSelection() || '').trim();
        const match = selected.match(/[\\p{L}\\p{M}\\p{N}]+(?:[’'\\-][\\p{L}\\p{M}\\p{N}]+)*/u);
        if (match) bridge.callHandler('$_aggregateWordHandler', token, match[0]);
      }, 0);
    });
    ${aggregateDictionarySelectionObserverJavascript()}
    resize();
    setTimeout(resize, 100);
    setTimeout(resize, 400);
  };
  for (const frame of document.querySelectorAll('iframe')) {
    frame.addEventListener('load', () => {
      setupFrame(frame);
      queueActiveDictionaryReport();
    });
  }
  for (const header of document.querySelectorAll('.dictionary-header')) {
    header.addEventListener('click', () => {
      if (selectedDictionaryMode) return;
      const section = header.closest('.dictionary-section');
      section.classList.toggle('collapsed');
      header.setAttribute('aria-expanded', String(!section.classList.contains('collapsed')));
      if (!section.classList.contains('collapsed')) {
        const frame = section.querySelector('iframe');
        frame.dataset.ready = '0';
        setupFrame(frame);
      }
      queueActiveDictionaryReport();
    });
  }
  queueActiveDictionaryReport();
})();
</script></body></html>''';
  }

  Future<NavigationActionPolicy> _handleNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url?.uriValue;
    if (uri == null) return NavigationActionPolicy.CANCEL;
    final selectionLookup = windowsSelectionLookupRequestForTesting(
      uri.toString(),
    );
    if (Platform.isWindows && selectionLookup != null) {
      final token = selectionLookup.token;
      if (token != null) {
        unawaited(
          _handleWindowsSelectionAction([
            token,
            'lookup',
            selectionLookup.text,
          ]),
        );
      }
      return NavigationActionPolicy.CANCEL;
    }
    if (_ownsSessionUri(uri)) return NavigationActionPolicy.ALLOW;
    if (uri.scheme == 'about' && uri.path == 'blank') {
      return NavigationActionPolicy.ALLOW;
    }
    return NavigationActionPolicy.CANCEL;
  }

  bool _ownsSessionUri(Uri uri) =>
      (_hostSession?.owns(uri) ?? false) ||
      _childSessions.values.any((session) => session.owns(uri));

  Future<void> _openLink(String token, String rawUrl) async {
    final target = dictionaryLinkForTesting(rawUrl);
    if (target?.headword case final headword?) {
      await _openHeadword(token, headword, target?.anchor);
    }
  }

  Future<void> _openHeadword(
    String token,
    String headword,
    String? anchor,
  ) async {
    final section = _sectionByToken[token];
    if (section == null) return;
    await widget.onOpenHeadword(
      section.article.mdxPath,
      headword,
      anchor,
      await _readScrollOffset(),
    );
  }

  Future<void> _copySelectedText() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final selection = await _readCurrentSelection();
      if (selection == null) {
        _showSelectionMessage('无法读取选中的文字，请重新选择后再试。');
        return;
      }
      await Clipboard.setData(ClipboardData(text: selection.text));
      await controller.clearFocus();
      _selectedText = null;
      _selectedToken = null;
      _showSelectionMessage('已复制');
    } catch (error) {
      debugPrint('Aggregate dictionary selection copy failed: $error');
      _showSelectionMessage('复制失败，请重新选择后再试。');
    }
  }

  Future<void> _handleWindowsSelectionAction(List<dynamic> arguments) async {
    if (!Platform.isWindows || arguments.length < 3) return;
    final token = arguments[0];
    final action = arguments[1];
    final rawText = arguments[2];
    if (token is! String ||
        !_sectionByToken.containsKey(token) ||
        action is! String ||
        rawText is! String) {
      return;
    }
    final text = rawText.trim();
    if (text.isEmpty) return;
    _selectedToken = token;
    _selectedText = text;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      _selectedToken = null;
      _selectedText = null;
      _showSelectionMessage('已复制');
      return;
    }
    if (action == 'lookup') {
      final headword = doubleClickLookupHeadwordForTesting(text);
      if (headword == null) {
        _showSelectionMessage('请选择一个单词后再查词。');
        return;
      }
      _selectedToken = null;
      _selectedText = null;
      await _openHeadword(token, headword, null);
    }
  }

  void _lookupSelectedText() {
    unawaited(_dispatchSelectedTextLookup());
  }

  Future<void> _dispatchSelectedTextLookup() async {
    try {
      // Let Android dismiss its native selection menu before replacing the
      // current lookup document.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      final selection = await _readCurrentSelection();
      final headword = doubleClickLookupHeadwordForTesting(selection?.text);
      if (headword == null) {
        _showSelectionMessage('请选择一个单词后再查词。');
        return;
      }
      final token = selection?.token ?? _activeDictionaryToken();
      if (token == null) return;
      await _webViewController?.clearFocus();
      _selectedText = null;
      _selectedToken = null;
      await _openHeadword(token, headword, null);
    } catch (error) {
      debugPrint('Aggregate dictionary selection lookup failed: $error');
      _showSelectionMessage('查词失败，请重新选择后再试。');
    }
  }

  Future<({String text, String? token})?> _readCurrentSelection({
    bool includeCached = true,
  }) async {
    final controller = _webViewController;
    if (controller == null) return null;
    try {
      final topLevelSelection = (await controller.getSelectedText())?.trim();
      if (topLevelSelection?.isNotEmpty == true) {
        return (
          text: topLevelSelection!,
          token: _selectedToken ?? _activeDictionaryToken(),
        );
      }
      final value = await controller.evaluateJavascript(
        source: '''
(() => {
  const active = document.querySelector('.dictionary-section.active');
  const all = Array.from(document.querySelectorAll('.dictionary-section'));
  const candidates = active
    ? [active, ...all.filter((section) => section !== active)]
    : all;
  for (const section of candidates) {
    const frame = section.querySelector('iframe');
    const doc = frame && frame.contentDocument;
    const selected = doc ? String(doc.getSelection() || '').trim() : '';
    if (selected) return {text: selected, token: section.dataset.token || null};
  }
  return null;
})();
''',
      );
      if (value is Map) {
        final text = value['text'];
        final token = value['token'];
        if (text is String && text.trim().isNotEmpty) {
          return (
            text: text.trim(),
            token: token is String ? token : _activeDictionaryToken(),
          );
        }
      }
    } catch (error) {
      debugPrint('Aggregate dictionary selection read failed: $error');
    }
    final cached = _selectedText?.trim();
    if (!includeCached || cached == null || cached.isEmpty) return null;
    return (
      text: cached,
      token: _selectedToken ?? _activeDictionaryToken(),
    );
  }

  String? _activeDictionaryToken() {
    final selectedPath = widget.initialMdxPath;
    return _sectionByToken.entries
            .where((entry) => entry.value.article.mdxPath == selectedPath)
            .map((entry) => entry.key)
            .firstOrNull ??
        _sectionByToken.keys.firstOrNull;
  }

  void _showSelectionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _scrollToDictionary(
    String mdxPath, {
    double? requestedOffset,
  }) async {
    final controller = _webViewController;
    final domId = _domIdByMdxPath[mdxPath];
    if (controller == null || domId == null) return false;
    try {
      if (widget.presentation ==
          AggregateArticlePresentation.selectedDictionary) {
        final offsetExpression = requestedOffset == null
            ? 'undefined'
            : requestedOffset.clamp(0, double.maxFinite).toString();
        final result = await controller.evaluateJavascript(
          source:
              'window.__lumalexShowDictionary(${jsonEncode(domId)}, $offsetExpression);',
        );
        return result == true;
      }
      final result = await controller.evaluateJavascript(
        source: '''
(() => {
  const section = document.getElementById(${jsonEncode(domId)});
  if (!section) return false;
  section.classList.remove('collapsed');
  const header = section.querySelector('.dictionary-header');
  if (header) header.setAttribute('aria-expanded', 'true');
  section.scrollIntoView({block: 'start', behavior: 'smooth'});
  return true;
})();
''',
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyTextScales(
    InAppWebViewController controller,
    Map<String, double> scalesByMdxPath,
  ) async {
    final scalesByDomId = <String, double>{
      for (final entry in scalesByMdxPath.entries)
        if (_domIdByMdxPath[entry.key] case final domId?) domId: entry.value,
    };
    if (scalesByDomId.isEmpty) return;
    try {
      await controller.evaluateJavascript(
        source: '''
(() => {
  const scales = ${jsonEncode(scalesByDomId)};
  for (const [domId, scale] of Object.entries(scales)) {
    const section = document.getElementById(domId);
    const frame = section && section.querySelector('iframe');
    const doc = frame && frame.contentDocument;
    if (!frame || !doc || !doc.documentElement) continue;
    frame.dataset.scale = String(scale);
    if (typeof doc.defaultView.__lumalexSetTextScale === 'function') {
      doc.defaultView.__lumalexSetTextScale(scale);
    }
    if (typeof frame.__lumalexResize === 'function') {
      frame.__lumalexResize();
    }
  }
})();
''',
      );
    } catch (_) {
      // A document reload may have replaced the frames while a scale update
      // was queued. The next build will apply the current scale on load.
    }
  }

  Future<void> _updateDictionaryTitle(String mdxPath, String title) async {
    final controller = _webViewController;
    final domId = _domIdByMdxPath[mdxPath];
    if (controller == null || domId == null) return;
    await controller.evaluateJavascript(
      source: '''
(() => {
  const section = document.getElementById(${jsonEncode(domId)});
  const titleElement = section && section.querySelector('.dictionary-header .title');
  if (titleElement) titleElement.textContent = ${jsonEncode(title)};
})();
''',
    );
  }

  Future<void> _scrollToAnchor(String mdxPath, String anchor) async {
    final controller = _webViewController;
    final domId = _domIdByMdxPath[mdxPath];
    if (controller == null || domId == null) return;
    await controller.evaluateJavascript(
      source: '''
(() => {
  const sectionId = ${jsonEncode(domId)};
  const anchor = ${jsonEncode(anchor)};
  let attempts = 0;
  const reveal = () => {
    const section = document.getElementById(sectionId);
    const frame = section && section.querySelector('iframe');
    const doc = frame && frame.contentDocument;
    const target = doc &&
      (doc.getElementById(anchor) || Array.from(doc.getElementsByName(anchor))[0]);
    if (!target) {
      if (attempts++ < 8) setTimeout(reveal, 80);
      return;
    }
    const frameRect = frame.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    window.scrollTo({
      top: window.scrollY + frameRect.top + targetRect.top - 8,
      behavior: 'smooth'
    });
  };
  reveal();
})();
''',
    );
  }

  Future<double> _readScrollOffset() async {
    final controller = _webViewController;
    if (controller == null) return 0;
    try {
      final value = await controller.evaluateJavascript(
        source: 'window.scrollY || document.documentElement.scrollTop || 0',
      );
      return value is num ? value.toDouble() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<CustomSchemeResponse> _loadCustomResource(
    WebResourceRequest request,
  ) async {
    final uri = request.url.uriValue;
    final resourcePath = switch (uri.scheme) {
      'dictres' when uri.host == 'resource' => uri.path,
      'sound' => dictionarySoundResourcePath(uri.toString()),
      _ => null,
    };
    if (resourcePath == null) return _emptyResource();
    final section = _sectionForReferer(request.headers) ??
        _sectionByToken.values.firstOrNull;
    if (section == null) return _emptyResource();
    try {
      final resource = await widget.engine.readResource(
        resourcePath,
        maxBytes: _maximumAggregateResourceBytes,
        mdxPath: section.article.mdxPath,
      );
      if (resource == null) return _emptyResource();
      return CustomSchemeResponse(
        contentType: resource.mimeType,
        data: resource.bytes,
      );
    } catch (_) {
      return _emptyResource();
    }
  }

  AggregateArticleSection? _sectionForReferer(Map<String, String>? headers) {
    if (headers == null) return null;
    final referer = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'referer')
        .map((entry) => entry.value)
        .firstOrNull;
    final uri = referer == null ? null : Uri.tryParse(referer);
    if (uri == null || uri.pathSegments.length < 2) return null;
    return _sectionByToken[uri.pathSegments[1]];
  }

  Future<void> _playSound(String token, String rawUri) async {
    final section = _sectionByToken[token];
    final resourcePath = dictionarySoundResourcePath(rawUri);
    if (section == null || resourcePath == null) {
      debugPrint('Dictionary audio URL could not be resolved: $rawUri');
      _showAudioError();
      return;
    }
    final request = ++_audioGeneration;
    try {
      await _textToSpeech.stop();
      final resource = await widget.engine.readResource(
        resourcePath,
        maxBytes: _maximumAggregateResourceBytes,
        mdxPath: section.article.mdxPath,
      );
      if (!mounted || request != _audioGeneration) return;
      if (resource == null) {
        debugPrint('Dictionary audio resource not found: $resourcePath');
        _showAudioError();
        return;
      }
      final player = _audioPlayer ??= AudioPlayer();
      // Keep the Windows MediaPlayer active between pronunciations. Stopping
      // here tears down the native decoder, which makes the first click only
      // initialize the backend and the second click become the audible one.
      if (player.playing) {
        await player.pause();
      }
      await _removeAudioDirectory();
      final directory = await Directory.systemTemp.createTemp('lumalex_audio_');
      final extension = resourcePath.split('.').last.toLowerCase();
      final safeExtension =
          RegExp(r'^[a-z0-9]{1,10}$').hasMatch(extension) ? extension : 'mp3';
      final file = File('${directory.path}/pronunciation.$safeExtension');
      await file.writeAsBytes(resource.bytes, flush: true);
      if (!mounted || request != _audioGeneration) {
        await directory.delete(recursive: true);
        return;
      }
      _activeAudioDirectory = directory;
      await player.setFilePath(
        file.path,
        initialPosition: Duration.zero,
      );
      if (!mounted || request != _audioGeneration) return;
      // just_audio_windows can publish a delayed `playing: false` event after
      // the load future completes. Without this small settling window it can
      // swallow the first play request, so the user only hears the second
      // click.
      if (Platform.isWindows) {
        await Future<void>.delayed(_windowsAudioLoadStabilizationDelay);
      }
      if (!mounted || request != _audioGeneration) return;
      unawaited(
        player.play().catchError((Object error) {
          debugPrint('Dictionary audio playback failed: $error');
          if (mounted && request == _audioGeneration) {
            _showAudioError();
          }
        }),
      );
    } catch (error) {
      debugPrint('Dictionary audio setup failed: $error');
      if (mounted && request == _audioGeneration) {
        _showAudioError();
      }
    }
  }

  Future<void> _speakExample(String text, String locale) async {
    _audioGeneration++;
    try {
      await _audioPlayer?.stop();
      await _textToSpeech.speak(text, locale: locale);
    } on PlatformException catch (error) {
      debugPrint(
          'Dictionary example TTS failed: ${error.code} ${error.message}');
      _showTextToSpeechError(error.message);
    } catch (error) {
      debugPrint('Dictionary example TTS failed: $error');
      _showTextToSpeechError(null);
    }
  }

  Future<void> _stopPlayback() async {
    _audioGeneration++;
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

  void _showAudioError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法播放此发音文件。')),
    );
  }

  void _showTextToSpeechError(String? detail) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(detail?.trim().isNotEmpty == true
            ? detail!
            : '无法使用系统英语语音。请安装英语文字转语音语音包后重试。'),
      ),
    );
  }

  Future<void> _removeAudioDirectory() async {
    final directory = _activeAudioDirectory;
    _activeAudioDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void _closeSessions() {
    _hostSession?.close();
    _hostSession = null;
    for (final session in _childSessions.values) {
      session.close();
    }
    _childSessions.clear();
    _sectionByToken.clear();
    _domIdByMdxPath.clear();
  }

  String _documentSignature(List<AggregateArticleSection> sections) => sections
      .map((section) =>
          '${section.article.mdxPath}\u{0}${section.article.headword}\u{0}${section.article.html.hashCode}')
      .join('\u{1}');

  Map<String, double> _changedTextScales(
    List<AggregateArticleSection> current,
    List<AggregateArticleSection> previous,
  ) {
    final previousByMdxPath = <String, double>{
      for (final section in previous)
        section.article.mdxPath: section.textScale,
    };
    return <String, double>{
      for (final section in current)
        if (previousByMdxPath[section.article.mdxPath] != section.textScale)
          section.article.mdxPath: section.textScale,
    };
  }

  CustomSchemeResponse _emptyResource() => CustomSchemeResponse(
        contentType: 'application/octet-stream',
        data: Uint8List(0),
      );
}
