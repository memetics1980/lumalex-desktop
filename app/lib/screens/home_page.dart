import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../app_version.dart';
import '../models/article.dart';
import '../models/dictionary_group.dart';
import '../models/dictionary_library_entry.dart';
import '../models/dictionary_result_navigation.dart';
import '../models/dictionary_result_position.dart';
import '../models/lookup_navigation.dart';
import '../models/lookup_result_cache.dart';
import '../models/reader_position_cache.dart';
import '../models/review_card.dart';
import '../models/retained_reader_order.dart';
import '../models/retained_reader_slots.dart';
import '../models/search_fallback.dart';
import '../platform/android_process_text_window.dart';
import '../platform/android_reader_memory.dart';
import '../platform/reader_platform_policy.dart';
import '../platform/desktop_platform.dart';
import '../platform/windows_window_lifecycle.dart';
import '../platform/windows_screen_lookup.dart';
import '../services/app_diagnostics.dart';
import '../services/dictionary_engine.dart';
import '../services/dictionary_content_server.dart';
import '../services/dictionary_file_access.dart';
import '../services/dictionary_folder_scanner.dart';
import '../services/dictionary_groups.dart';
import '../services/dictionary_library.dart';
import '../services/dictionary_reader_prewarmer.dart';
import '../services/dictionary_text_to_speech.dart';
import '../services/ios_dictionary_home.dart';
import '../services/learning_data_transfer.dart';
import '../services/reader_diagnostics.dart';
import '../services/screen_lookup_ai.dart';
import '../services/word_records.dart';
import '../services/windows_app_settings.dart';
import 'aggregate_article_page.dart';
import 'app_settings_page.dart';
import 'app_diagnostics_sheet.dart';
import 'article_page.dart';

enum _AppDestination { lookup, wordbook, dictionaries }

const lookupCorrectionDisplayDuration = Duration(seconds: 6);
const _maximumScreenLookupAudioBytes = 20 * 1024 * 1024;
const _windowsScreenLookupAudioDelay = Duration(milliseconds: 80);

typedef _DictionaryImportTarget = ({
  List<String> mdxPaths,
  String accessPath,
  bool copiedIntoIosHome,
  int skippedFolderCount,
  Map<String, List<String>> mddPathsByMdx,
  Map<String, List<DictionarySidecarResource>> sidecarResourcesByMdx,
  Map<String, AndroidDictionarySource> androidSourcesByMdx,
});

const _dictionaryGroupColors = <Color>[
  Color(0xFF087E87),
  Color(0xFF356FD4),
  Color(0xFF2D8A57),
  Color(0xFFD08A16),
  Color(0xFF7B57C2),
  Color(0xFFC6536A),
];

const _dictionaryGroupColorNames = <String>[
  '青绿',
  '蓝色',
  '绿色',
  '琥珀',
  '紫色',
  '玫红',
];

double destinationPageMaxWidthForOperatingSystem(
  String operatingSystem, {
  required double fallback,
}) =>
    operatingSystem.toLowerCase() == 'windows' ? 2400 : fallback;

String _screenLookupAudioExtension(String resourcePath) {
  final dot = resourcePath.lastIndexOf('.');
  if (dot < 1 || dot == resourcePath.length - 1) return 'mp3';
  final extension = resourcePath.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,10}$').hasMatch(extension) ? extension : 'mp3';
}

@visibleForTesting
String encodeScreenLookupAiPayload(Map<String, Object?> payload) =>
    base64Encode(utf8.encode(jsonEncode(payload)));

@visibleForTesting
List<DictionaryLibraryEntry> screenLookupEntriesInGroupOrder(
  Iterable<DictionaryLibraryEntry> entries,
  Iterable<DictionaryGroup> groups,
) {
  final source = entries.toList(growable: false);
  final knownGroupIds = groups.map((group) => group.id).toSet();
  return <DictionaryLibraryEntry>[
    for (final group in groups)
      ...source.where((entry) => entry.groupId == group.id),
    ...source.where(
      (entry) =>
          entry.groupId == null || !knownGroupIds.contains(entry.groupId),
    ),
  ];
}

@visibleForTesting
List<int> screenLookupIndexesForScope(
  List<DictionaryLibraryEntry> entries,
  List<DictionaryGroup> groups,
  String scopeId,
) {
  final knownGroupIds = groups.map((group) => group.id).toSet();
  return [
    for (var index = 0; index < entries.length; index++)
      if (scopeId == DictionaryGroupScope.all ||
          (scopeId == DictionaryGroupScope.ungrouped
              ? entries[index].groupId == null ||
                  !knownGroupIds.contains(entries[index].groupId)
              : entries[index].groupId == scopeId))
        index,
  ];
}

@visibleForTesting
String buildScreenLookupDictionaryOptions({
  required List<DictionaryLibraryEntry> entries,
  required List<DictionaryGroup> groups,
  required int selectedIndex,
}) {
  const elementEscape = HtmlEscape(HtmlEscapeMode.element);
  const attributeEscape = HtmlEscape(HtmlEscapeMode.attribute);
  final knownGroupIds = groups.map((group) => group.id).toSet();

  String optionAt(int index) =>
      '<option value="$index"${index == selectedIndex ? ' selected' : ''}>'
      '${elementEscape.convert(entries[index].title)}</option>';

  String optionGroup(String label, Iterable<int> indexes) {
    final values = indexes.toList(growable: false);
    if (values.isEmpty) return '';
    final safeLabel = attributeEscape.convert('$label · ${values.length} 本');
    return '<optgroup label="$safeLabel">'
        '${values.map(optionAt).join()}</optgroup>';
  }

  return <String>[
    for (final group in groups)
      optionGroup(
        group.name,
        Iterable<int>.generate(entries.length)
            .where((index) => entries[index].groupId == group.id),
      ),
    optionGroup(
      '未分组',
      Iterable<int>.generate(entries.length).where(
        (index) =>
            entries[index].groupId == null ||
            !knownGroupIds.contains(entries[index].groupId),
      ),
    ),
  ].join();
}

@visibleForTesting
String buildScreenLookupDictionaryMenu({
  required List<DictionaryLibraryEntry> entries,
  required List<DictionaryGroup> groups,
  required int selectedIndex,
  required String scopeId,
}) {
  const elementEscape = HtmlEscape(HtmlEscapeMode.element);
  final knownGroupIds = groups.map((group) => group.id).toSet();

  String groupItems(
      String name, int scopeCode, String groupScopeId, Iterable<int> indexes) {
    final values = indexes.toList(growable: false);
    if (values.isEmpty) return '';
    return '<div class="lumalex-screen-menu-group" role="group">'
        '<button type="button" class="lumalex-screen-menu-heading'
        '${scopeId == groupScopeId ? ' selected' : ''}" '
        'aria-pressed="${scopeId == groupScopeId}" '
        'onclick="lumalexSelectScope($scopeCode)">'
        '${elementEscape.convert(name)} · ${values.length} 本'
        '<span>仅查此组</span></button>'
        '${values.map((index) => '<button type="button" role="option" '
            'aria-selected="${index == selectedIndex}" '
            'class="lumalex-screen-menu-item${index == selectedIndex ? ' selected' : ''}" '
            'data-index="$index" onclick="lumalexSelectDictionary($index)">'
            '${elementEscape.convert(entries[index].title)}</button>').join()}'
        '</div>';
  }

  return <String>[
    '<button type="button" class="lumalex-screen-menu-heading'
        '${scopeId == DictionaryGroupScope.all ? ' selected' : ''}" '
        'aria-pressed="${scopeId == DictionaryGroupScope.all}" '
        'onclick="lumalexSelectScope(-1)">'
        '全部词典 · ${entries.length} 本<span>跨组查找</span></button>',
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++)
      groupItems(
        groups[groupIndex].name,
        groupIndex,
        groups[groupIndex].id,
        Iterable<int>.generate(entries.length)
            .where((index) => entries[index].groupId == groups[groupIndex].id),
      ),
    groupItems(
      '未分组',
      -2,
      DictionaryGroupScope.ungrouped,
      Iterable<int>.generate(entries.length).where(
        (index) =>
            entries[index].groupId == null ||
            !knownGroupIds.contains(entries[index].groupId),
      ),
    ),
  ].join();
}

class LookupHomeButton extends StatelessWidget {
  const LookupHomeButton({
    required this.iconOnly,
    required this.onPressed,
    super.key,
  });

  final bool iconOnly;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      return IconButton(
        key: const ValueKey('lookup-home-icon-button'),
        tooltip: '返回查词首页',
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_back_rounded),
        style: IconButton.styleFrom(minimumSize: const Size.square(44)),
      );
    }
    return Tooltip(
      message: '结束当前阅读并返回查词首页',
      child: TextButton.icon(
        key: const ValueKey('lookup-home-labeled-button'),
        onPressed: onPressed,
        icon: const Icon(Icons.search_rounded, size: 20),
        label: const Text('查词首页'),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class ReaderTextScaleToggleButton extends StatelessWidget {
  const ReaderTextScaleToggleButton({
    required this.expanded,
    required this.onPressed,
    super.key,
  });

  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: expanded ? '收起字号调整' : '调整字号',
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(44),
          backgroundColor: expanded
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
        ),
        icon: Text(
          'Aa',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: expanded
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}

class ReaderFavoriteButton extends StatelessWidget {
  const ReaderFavoriteButton({
    required this.favorite,
    required this.onPressed,
    super.key,
  });

  final bool favorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('reader-favorite-button'),
      tooltip: favorite ? '取消收藏' : '收藏单词',
      onPressed: onPressed,
      iconSize: 30,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        backgroundColor: Colors.transparent,
        foregroundColor:
            favorite ? const Color(0xFFF2A51A) : colors.onSurfaceVariant,
        overlayColor: colors.primary.withValues(alpha: 0.12),
      ),
      icon: Icon(
        favorite ? Icons.star_rounded : Icons.star_outline_rounded,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    required this.engine,
    required this.dictionaryGroups,
    required this.library,
    required this.wordRecords,
    required this.windowsAppSettings,
    this.initialQuery = '',
    this.processTextMode = false,
    this.readerPlatformPolicy,
    super.key,
  });

  final DictionaryEngine engine;
  final DictionaryGroupsStore dictionaryGroups;
  final DictionaryLibrary library;
  final WordRecordsStore wordRecords;
  final WindowsAppSettingsStore windowsAppSettings;
  final String initialQuery;
  final bool processTextMode;
  final ReaderPlatformPolicy? readerPlatformPolicy;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _queryController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _desktopDictionaryMenuController = MenuController();
  final _desktopDictionaryAnchorKey = GlobalKey();
  final _desktopDictionaryInlineScrollController = ScrollController();
  final _desktopDictionaryPopupScrollController = ScrollController();
  Timer? _desktopDictionaryHoverTimer;
  Timer? _desktopDictionaryExitTimer;
  bool _desktopDictionaryMenuHeldOpen = false;
  late final _readerPlatformPolicy =
      widget.readerPlatformPolicy ?? ReaderPlatformPolicy.current;
  late int _maximumRetainedReaders;
  AndroidReaderMemoryProfile? _androidReaderMemoryProfile;
  // A fully rendered ODE_2024 entry can approach 1 MB of HTML before WebKit
  // expands it into a DOM, styles and decoded image resources. Retaining
  // several invisible WKWebViews is a memory-risk on iPhone/iPad.
  // Keep a small LRU of rendered dictionaries for the current word. Returning
  // to a recent dictionary becomes a pure IndexedStack switch instead of a
  // full Chromium navigation, while a 10+ dictionary library cannot create
  // an unbounded number of platform WebViews.
  final Map<String, ArticlePageController> _articleControllers = {};
  final _aggregateArticleController = AggregateArticlePageController();
  List<String> _retainedReaderPaths = const [];
  late List<String?> _retainedReaderSlots;
  final _readerPositionCache = ReaderPositionCache();
  String _readerQuery = '';
  Map<String, List<Article>> _articlesByDictionary = const {};
  Set<String> _availableMdxPaths = const {};
  final Set<String> _failedMdxPaths = {};
  final Map<String, Future<bool>> _dictionaryPreparations = {};
  double _textScale = 1;
  List<String> _history = const [];
  List<String> _favorites = const [];
  List<ReviewCard> _reviewCards = const [];
  String? _selectedMdxPath;
  String? _articleAnchor;
  double? _articleScrollOffset;
  ({String original, String replacement})? _lookupCorrection;
  bool _isSearching = false;
  bool _isImporting = false;
  bool _isScanningIosDictionaryHome = false;
  bool _isRefreshingIosSources = false;
  bool _isLibraryLoading = true;
  List<DictionaryLibraryEntry> _libraryEntries = const [];
  DictionaryGroupSnapshot _dictionaryGroupSnapshot =
      const DictionaryGroupSnapshot();
  final Set<String> _expandedDictionaryGroupIds = <String>{};
  List<String> _suggestions = const [];
  int _selectedSuggestionIndex = -1;
  Timer? _suggestionDebounce;
  Timer? _lookupCorrectionTimer;
  Timer? _indexMigrationDelay;
  Timer? _dictionaryWarmupDelay;
  Timer? _readerWarmupDelay;
  Timer? _readerControlsTimer;
  Timer? _readerPreloadDelay;
  Timer? _readerRecoveryDelay;
  Timer? _iosDictionaryHomeScanDelay;
  Timer? _wordRecordsRefreshDelay;
  DateTime? _iosReaderBackgroundedAt;
  int _dictionaryWarmupGeneration = 0;
  int _suggestionRequest = 0;
  int _lookupRequest = 0;
  int _wordRecordsMutationGeneration = 0;
  late final Future<void> _wordRecordsReady;
  late final Future<Directory?> _iosDictionaryHomeReady;
  late final Future<void> _libraryReady;
  final _fileAccess = DictionaryFileAccess();
  final _appDiagnostics = AppDiagnosticsService();
  final _windowsWindowLifecycle = DesktopWindowLifecycle();
  final _windowsScreenLookup = DesktopScreenLookup();
  final _iosDictionaryHome = IosDictionaryHome();
  final _lookupNavigation = LookupNavigationHistory();
  final _lookupResultCache = LookupResultCache();
  _AppDestination _destination = _AppDestination.lookup;
  WindowsCloseBehavior _windowsCloseBehavior = WindowsCloseBehavior.exitApp;
  bool _windowsTrayNotificationShown = false;
  bool _windowsCloseBehaviorSaving = false;
  bool _windowsScreenLookupEnabled = false;
  bool _windowsScreenLookupSaving = false;
  bool _macosAccessibilityGranted = false;
  WindowsScreenLookupShortcut _windowsScreenLookupShortcut =
      WindowsScreenLookupShortcut.ctrlAltL;
  int _screenLookupRequest = 0;
  DictionaryContentSession? _screenLookupContentSession;
  List<DictionaryLibraryEntry> _screenLookupEntries = const [];
  String? _screenLookupScopeId;
  String? _screenLookupQuery;
  int _screenLookupX = 0;
  int _screenLookupY = 0;
  int _screenLookupDictionaryIndex = 0;
  bool _screenLookupPinned = false;
  Article? _screenLookupArticle;
  AudioPlayer? _screenLookupAudioPlayer;
  Directory? _screenLookupAudioDirectory;
  int _screenLookupAudioRequest = 0;
  final _screenLookupTextToSpeech = DictionaryTextToSpeech();
  final _screenLookupAiClient = ScreenLookupAiClient();
  final _screenLookupAiBaseUrlController =
      TextEditingController(text: defaultScreenLookupAiBaseUrl);
  final _screenLookupAiModelController = TextEditingController();
  final _screenLookupAiApiKeyController = TextEditingController();
  bool _windowsScreenLookupAiEnabled = false;
  bool _windowsScreenLookupAiSaving = false;
  bool _windowsScreenLookupAiKeyStored = false;
  String _windowsScreenLookupAiBaseUrl = defaultScreenLookupAiBaseUrl;
  String _windowsScreenLookupAiModel = '';
  String _screenLookupContext = '';
  int _screenLookupAiRequest = 0;
  Map<String, Object?>? _screenLookupAiPayload;
  bool _showSettingsPage = false;
  bool _showReaderTextControls = false;
  bool _reviewAnswerVisible = false;
  double _dictionarySelectorDragDistance = 0;

  @override
  void initState() {
    super.initState();
    _maximumRetainedReaders = _readerPlatformPolicy.maximumRetainedReaders;
    _retainedReaderSlots = List<String?>.filled(
      _readerPlatformPolicy.maximumRetainedReaders,
      null,
      growable: false,
    );
    WidgetsBinding.instance.addObserver(this);
    if (isLumaLexDesktop) {
      _windowsWindowLifecycle.attach(_handleWindowsWindowLifecycleEvent);
      _windowsScreenLookup.attach(_handleWindowsScreenLookupEvent);
      unawaited(_loadWindowsAppSettings());
    }
    _searchFocusNode.onKeyEvent = _handleSearchKeyEvent;
    final initialQuery = widget.initialQuery.trim();
    if (initialQuery.isNotEmpty) {
      _queryController.value = TextEditingValue(
        text: initialQuery,
        selection: TextSelection.collapsed(offset: initialQuery.length),
      );
    }
    _iosDictionaryHomeReady = _iosDictionaryHome.ensureExists();
    _libraryReady = _loadLibrary();
    if (initialQuery.isNotEmpty) {
      unawaited(
        _libraryReady.then((_) async {
          if (!mounted || _availableEntries.isEmpty) return;
          await _startNewLookup(initialQuery);
        }),
      );
    }
    if (Platform.isIOS) {
      unawaited(_scanIosDictionaryHomeAfterStartup(_libraryReady));
    }
    _wordRecordsReady = _loadWordRecords();
    if (_readerPlatformPolicy.adaptiveReaderRetention) {
      unawaited(_loadAndroidReaderMemoryProfile());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Mobile is where cold WebView startup is visible and where a process
      // normally lives for the whole session. Desktop widget tests and short
      // desktop windows should not acquire a permanent loopback listener just
      // for showing an empty library.
      if (Platform.isAndroid || Platform.isIOS) {
        unawaited(DictionaryContentServer.instance.prewarm());
        _readerWarmupDelay = Timer(const Duration(milliseconds: 250), () {
          if (mounted) {
            unawaited(DictionaryReaderPrewarmer.instance.prewarm());
          }
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _suggestionDebounce?.cancel();
    _lookupCorrectionTimer?.cancel();
    _indexMigrationDelay?.cancel();
    _dictionaryWarmupDelay?.cancel();
    _dictionaryWarmupGeneration++;
    _readerWarmupDelay?.cancel();
    unawaited(DictionaryReaderPrewarmer.instance.disposeUnused());
    _readerControlsTimer?.cancel();
    _readerPreloadDelay?.cancel();
    _readerRecoveryDelay?.cancel();
    _iosDictionaryHomeScanDelay?.cancel();
    _wordRecordsRefreshDelay?.cancel();
    _desktopDictionaryHoverTimer?.cancel();
    _desktopDictionaryExitTimer?.cancel();
    _desktopDictionaryInlineScrollController.dispose();
    _desktopDictionaryPopupScrollController.dispose();
    if (isLumaLexDesktop) {
      _windowsWindowLifecycle.detach();
      _windowsScreenLookup.detach();
    }
    _screenLookupRequest++;
    _screenLookupAiRequest++;
    _screenLookupContentSession?.close();
    _screenLookupAudioRequest++;
    unawaited(_screenLookupAudioPlayer?.dispose());
    unawaited(_screenLookupTextToSpeech.stop());
    unawaited(_removeScreenLookupAudioCache());
    _searchFocusNode.dispose();
    _queryController.dispose();
    _screenLookupAiBaseUrlController.dispose();
    _screenLookupAiModelController.dispose();
    _screenLookupAiApiKeyController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleWordRecordsRefresh();
      if (Platform.isMacOS) unawaited(_refreshMacosAccessibilityPermission());
    }
    if (Platform.isAndroid) {
      if (state == AppLifecycleState.resumed) {
        _restoreAndroidReaderRetentionLimit();
      }
      return;
    }
    if (!Platform.isIOS) {
      return;
    }
    if (state != AppLifecycleState.resumed) {
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        _iosReaderBackgroundedAt ??= DateTime.now();
      }
      if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        _setMaximumRetainedReaders(
          _readerPlatformPolicy.memoryPressureRetainedReaders,
        );
      }
      return;
    }

    _setMaximumRetainedReaders(
      _readerPlatformPolicy.maximumRetainedReaders,
    );
    final backgroundedAt = _iosReaderBackgroundedAt;
    _iosReaderBackgroundedAt = null;
    final backgroundDuration = backgroundedAt == null
        ? Duration.zero
        : DateTime.now().difference(backgroundedAt);
    _readerRecoveryDelay?.cancel();
    _readerRecoveryDelay = Timer(const Duration(milliseconds: 350), () {
      _readerRecoveryDelay = null;
      if (mounted) {
        unawaited(
          _recoverReadersAfterForeground(
            backgroundDuration: backgroundDuration,
          ),
        );
      }
    });
    _iosDictionaryHomeScanDelay?.cancel();
    _iosDictionaryHomeScanDelay = Timer(
      const Duration(milliseconds: 700),
      () {
        _iosDictionaryHomeScanDelay = null;
        if (mounted && !_isLibraryLoading && !_isImporting) {
          unawaited(_refreshIosSourcesAfterForeground());
        }
      },
    );
  }

  void _scheduleWordRecordsRefresh() {
    _wordRecordsRefreshDelay?.cancel();
    // PROCESS_TEXT is hosted by a second Flutter engine. Both engines use the
    // same uncached SharedPreferencesAsync store, but each HomePage keeps its
    // own in-memory view of history and favorites. Give any final platform
    // write from the closing floating Activity a moment to finish, then make
    // the launcher reflect that shared durable state when it returns.
    _wordRecordsRefreshDelay = Timer(const Duration(milliseconds: 200), () {
      _wordRecordsRefreshDelay = null;
      if (mounted) {
        unawaited(_refreshWordRecords());
      }
    });
  }

  Future<String> _loadWindowsScreenLookupAiApiKey() async {
    try {
      return await _windowsScreenLookup.loadAiApiKey();
    } on MissingPluginException catch (error) {
      debugPrint('Windows AI credential channel is unavailable: $error');
      return '';
    } on PlatformException catch (error) {
      debugPrint(
        'Windows AI credential could not be loaded: '
        '${error.code} ${error.message}',
      );
      return '';
    }
  }

  Future<void> _loadWindowsAppSettings() async {
    try {
      final values = await Future.wait<Object>([
        widget.windowsAppSettings.loadCloseBehavior(),
        widget.windowsAppSettings.loadTrayNotificationShown(),
        widget.windowsAppSettings.loadScreenLookupEnabled(),
        widget.windowsAppSettings.loadScreenLookupShortcut(),
        widget.windowsAppSettings.loadScreenLookupAiEnabled(),
        widget.windowsAppSettings.loadScreenLookupAiBaseUrl(),
        widget.windowsAppSettings.loadScreenLookupAiModel(),
        _loadWindowsScreenLookupAiApiKey(),
      ]);
      if (!mounted) return;
      var closeBehavior = values[0] as WindowsCloseBehavior;
      final trayNotificationShown = values[1] as bool;
      final screenLookupEnabled = values[2] as bool;
      final screenLookupShortcut = values[3] as WindowsScreenLookupShortcut;
      final screenLookupAiEnabled = values[4] as bool;
      final screenLookupAiBaseUrl = values[5] as String;
      final screenLookupAiModel = values[6] as String;
      final screenLookupAiApiKey = values[7] as String;
      if (screenLookupEnabled &&
          closeBehavior != WindowsCloseBehavior.hideToTray) {
        closeBehavior = WindowsCloseBehavior.hideToTray;
        await widget.windowsAppSettings.saveCloseBehavior(closeBehavior);
      }
      setState(() {
        _windowsCloseBehavior = closeBehavior;
        _windowsTrayNotificationShown = trayNotificationShown;
        _windowsScreenLookupEnabled = screenLookupEnabled;
        _windowsScreenLookupShortcut = screenLookupShortcut;
        _windowsScreenLookupAiEnabled = screenLookupAiEnabled;
        _windowsScreenLookupAiBaseUrl = screenLookupAiBaseUrl;
        _windowsScreenLookupAiModel = screenLookupAiModel;
        _windowsScreenLookupAiKeyStored = screenLookupAiApiKey.isNotEmpty;
        _screenLookupAiBaseUrlController.text = screenLookupAiBaseUrl;
        _screenLookupAiModelController.text = screenLookupAiModel;
      });
      await _refreshMacosAccessibilityPermission();
      await _applyWindowsCloseBehavior();
      final screenLookupApplied = await _applyDesktopScreenLookup();
      if (screenLookupEnabled && !screenLookupApplied && mounted) {
        setState(() => _windowsScreenLookupEnabled = false);
        await widget.windowsAppSettings.saveScreenLookupEnabled(false);
        _showMessage('屏幕取词未能启动。快捷键可能已被占用，或系统$desktopBackgroundLocation暂不可用。');
      }
    } catch (error) {
      debugPrint('Windows app settings could not be loaded: $error');
      await _applyWindowsCloseBehavior();
      await _applyDesktopScreenLookup();
    }
  }

  Future<void> _refreshMacosAccessibilityPermission() async {
    if (!Platform.isMacOS) return;
    try {
      final granted = await _windowsScreenLookup.hasAccessibilityPermission();
      if (mounted) setState(() => _macosAccessibilityGranted = granted);
    } on MissingPluginException {
      // Widget tests have no native accessibility service.
    }
  }

  Future<void> _openMacosAccessibilitySettings() async {
    await _windowsScreenLookup.openAccessibilitySettings();
    await _refreshMacosAccessibilityPermission();
  }

  Future<bool> _applyWindowsCloseBehavior() async {
    try {
      await _windowsWindowLifecycle.configure(
        closeBehavior: _windowsCloseBehavior,
        showFirstHideNotification: !_windowsTrayNotificationShown,
      );
      return true;
    } on MissingPluginException catch (error) {
      debugPrint('Windows window lifecycle channel is unavailable: $error');
      return false;
    } on PlatformException catch (error) {
      debugPrint(
        'Windows close behavior could not be applied: '
        '${error.code} ${error.message}',
      );
      return false;
    }
  }

  Future<void> _setWindowsCloseBehavior(
    WindowsCloseBehavior closeBehavior,
  ) async {
    if (_windowsScreenLookupEnabled &&
        closeBehavior == WindowsCloseBehavior.exitApp) {
      _showMessage('屏幕取词需要 LumaLex 在后台运行，请先关闭屏幕取词。');
      return;
    }
    if (_windowsCloseBehaviorSaving || _windowsCloseBehavior == closeBehavior) {
      return;
    }
    final previous = _windowsCloseBehavior;
    setState(() {
      _windowsCloseBehavior = closeBehavior;
      _windowsCloseBehaviorSaving = true;
    });
    try {
      await widget.windowsAppSettings.saveCloseBehavior(closeBehavior);
      final applied = await _applyWindowsCloseBehavior();
      if (!applied && mounted) {
        _showMessage('关闭行为已保存，但当前窗口暂时无法应用该设置。');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _windowsCloseBehavior = previous);
      _showMessage('无法保存关闭行为设置。');
      await _applyWindowsCloseBehavior();
    } finally {
      if (mounted) {
        setState(() => _windowsCloseBehaviorSaving = false);
      }
    }
  }

  Future<bool> _applyDesktopScreenLookup() async {
    try {
      await _windowsScreenLookup.configure(
        enabled: _windowsScreenLookupEnabled,
        shortcut: _windowsScreenLookupShortcut,
      );
      return true;
    } on MissingPluginException catch (error) {
      debugPrint('Windows screen lookup channel is unavailable: $error');
      return false;
    } on PlatformException catch (error) {
      debugPrint(
        'Windows screen lookup could not be applied: '
        '${error.code} ${error.message}',
      );
      return false;
    }
  }

  Future<void> _setWindowsScreenLookupEnabled(bool enabled) async {
    if (_windowsScreenLookupSaving || _windowsScreenLookupEnabled == enabled) {
      return;
    }
    final previousEnabled = _windowsScreenLookupEnabled;
    final previousCloseBehavior = _windowsCloseBehavior;
    setState(() {
      _windowsScreenLookupEnabled = enabled;
      _windowsScreenLookupSaving = true;
      if (enabled) {
        _windowsCloseBehavior = WindowsCloseBehavior.hideToTray;
      }
    });
    try {
      if (enabled && previousCloseBehavior != WindowsCloseBehavior.hideToTray) {
        await widget.windowsAppSettings.saveCloseBehavior(
          WindowsCloseBehavior.hideToTray,
        );
        await _applyWindowsCloseBehavior();
      }
      await widget.windowsAppSettings.saveScreenLookupEnabled(enabled);
      final applied = await _applyDesktopScreenLookup();
      if (!applied) {
        throw StateError('screen lookup could not be enabled');
      }
    } catch (error) {
      if (!mounted) return;
      _windowsScreenLookupEnabled = previousEnabled;
      _windowsCloseBehavior = previousCloseBehavior;
      await Future.wait<void>([
        widget.windowsAppSettings.saveScreenLookupEnabled(previousEnabled),
        widget.windowsAppSettings.saveCloseBehavior(previousCloseBehavior),
      ]);
      await _applyWindowsCloseBehavior();
      await _applyDesktopScreenLookup();
      _showMessage(
        enabled ? '无法启用屏幕取词。快捷键可能已被占用，或系统托盘暂不可用。' : '无法关闭屏幕取词，请稍后重试。',
      );
    } finally {
      if (mounted) {
        setState(() => _windowsScreenLookupSaving = false);
      }
    }
  }

  Future<void> _setWindowsScreenLookupShortcut(
    WindowsScreenLookupShortcut shortcut,
  ) async {
    if (_windowsScreenLookupSaving ||
        _windowsScreenLookupShortcut == shortcut) {
      return;
    }
    final previous = _windowsScreenLookupShortcut;
    setState(() {
      _windowsScreenLookupShortcut = shortcut;
      _windowsScreenLookupSaving = true;
    });
    try {
      await widget.windowsAppSettings.saveScreenLookupShortcut(shortcut);
      final applied = await _applyDesktopScreenLookup();
      if (!applied) {
        throw StateError('screen lookup shortcut could not be registered');
      }
    } catch (error) {
      if (!mounted) return;
      _windowsScreenLookupShortcut = previous;
      await widget.windowsAppSettings.saveScreenLookupShortcut(previous);
      await _applyDesktopScreenLookup();
      _showMessage('这个快捷键已被其他程序占用，请选择另一个。');
    } finally {
      if (mounted) {
        setState(() => _windowsScreenLookupSaving = false);
      }
    }
  }

  ScreenLookupAiSettings _screenLookupAiSettingsFromEditors({
    bool? enabled,
  }) =>
      ScreenLookupAiSettings(
        enabled: enabled ?? _windowsScreenLookupAiEnabled,
        baseUrl: _screenLookupAiBaseUrlController.text.trim(),
        model: _screenLookupAiModelController.text.trim(),
      );

  ScreenLookupAiSettings get _savedScreenLookupAiSettings =>
      ScreenLookupAiSettings(
        enabled: _windowsScreenLookupAiEnabled,
        baseUrl: _windowsScreenLookupAiBaseUrl,
        model: _windowsScreenLookupAiModel,
      );

  bool get _screenLookupAiConfigured => _savedScreenLookupAiSettings.configured(
        apiKeyPresent: _windowsScreenLookupAiKeyStored,
      );

  String? _validateScreenLookupAiSettings(
    ScreenLookupAiSettings settings, {
    required bool apiKeyPresent,
  }) {
    if (!isAllowedScreenLookupAiBaseUrl(settings.baseUrl)) {
      return 'API 地址必须使用 HTTPS；本机服务可以使用 localhost 或 127.0.0.1。';
    }
    if (settings.model.isEmpty) return '请填写模型名称。';
    if (!apiKeyPresent) return '请填写并保存 API Key。';
    return null;
  }

  Future<void> _setWindowsScreenLookupAiEnabled(bool enabled) async {
    if (_windowsScreenLookupAiSaving ||
        _windowsScreenLookupAiEnabled == enabled) {
      return;
    }
    if (enabled) {
      final validation = _validateScreenLookupAiSettings(
        _screenLookupAiSettingsFromEditors(enabled: true),
        apiKeyPresent: _windowsScreenLookupAiKeyStored,
      );
      if (validation != null) {
        _showMessage('请先保存 AI 配置：$validation');
        return;
      }
    }
    setState(() {
      _windowsScreenLookupAiEnabled = enabled;
      _windowsScreenLookupAiSaving = true;
    });
    try {
      await widget.windowsAppSettings.saveScreenLookupAiEnabled(enabled);
      _showMessage(enabled ? 'AI 本句义项已启用；只会在点击 AI 按钮后发送上下文。' : 'AI 本句义项已关闭。');
    } catch (error) {
      if (mounted) {
        setState(() => _windowsScreenLookupAiEnabled = !enabled);
        _showMessage('无法保存 AI 开关。');
      }
    } finally {
      if (mounted) setState(() => _windowsScreenLookupAiSaving = false);
    }
  }

  Future<void> _saveWindowsScreenLookupAiSettings() async {
    if (_windowsScreenLookupAiSaving) return;
    final settings = _screenLookupAiSettingsFromEditors();
    final typedApiKey = _screenLookupAiApiKeyController.text.trim();
    final validation = _validateScreenLookupAiSettings(
      settings,
      apiKeyPresent: typedApiKey.isNotEmpty || _windowsScreenLookupAiKeyStored,
    );
    if (validation != null) {
      _showMessage(validation);
      return;
    }
    setState(() => _windowsScreenLookupAiSaving = true);
    try {
      if (typedApiKey.isNotEmpty) {
        await _windowsScreenLookup.saveAiApiKey(typedApiKey);
      }
      await Future.wait<void>([
        widget.windowsAppSettings.saveScreenLookupAiBaseUrl(settings.baseUrl),
        widget.windowsAppSettings.saveScreenLookupAiModel(settings.model),
      ]);
      if (!mounted) return;
      setState(() {
        _windowsScreenLookupAiBaseUrl = settings.baseUrl;
        _windowsScreenLookupAiModel = settings.model;
        if (typedApiKey.isNotEmpty) _windowsScreenLookupAiKeyStored = true;
        _screenLookupAiApiKeyController.clear();
      });
      _showMessage('AI 配置已保存，API Key 已写入 $desktopCredentialStore。');
    } on MissingPluginException {
      _showMessage('当前环境不支持 $desktopCredentialStore，API Key 未保存。');
    } on PlatformException catch (error) {
      debugPrint('AI settings could not be saved: ${error.code}');
      _showMessage('无法安全保存 AI 配置。');
    } catch (error) {
      debugPrint('AI settings could not be saved: $error');
      _showMessage('无法保存 AI 配置。');
    } finally {
      if (mounted) setState(() => _windowsScreenLookupAiSaving = false);
    }
  }

  Future<void> _deleteWindowsScreenLookupAiApiKey() async {
    if (_windowsScreenLookupAiSaving || !_windowsScreenLookupAiKeyStored) {
      return;
    }
    setState(() => _windowsScreenLookupAiSaving = true);
    try {
      await _windowsScreenLookup.deleteAiApiKey();
      await widget.windowsAppSettings.saveScreenLookupAiEnabled(false);
      if (!mounted) return;
      setState(() {
        _windowsScreenLookupAiKeyStored = false;
        _windowsScreenLookupAiEnabled = false;
        _screenLookupAiApiKeyController.clear();
      });
      _showMessage('已从 $desktopCredentialStore中删除 API Key。');
    } catch (error) {
      debugPrint('AI API key could not be deleted: $error');
      _showMessage('无法删除 API Key。');
    } finally {
      if (mounted) setState(() => _windowsScreenLookupAiSaving = false);
    }
  }

  Future<void> _testWindowsScreenLookupAiSettings() async {
    if (_windowsScreenLookupAiSaving) return;
    final settings = _screenLookupAiSettingsFromEditors(enabled: true);
    final typedApiKey = _screenLookupAiApiKeyController.text.trim();
    final validation = _validateScreenLookupAiSettings(
      settings,
      apiKeyPresent: typedApiKey.isNotEmpty || _windowsScreenLookupAiKeyStored,
    );
    if (validation != null) {
      _showMessage(validation);
      return;
    }
    setState(() => _windowsScreenLookupAiSaving = true);
    try {
      final apiKey = typedApiKey.isNotEmpty
          ? typedApiKey
          : await _loadWindowsScreenLookupAiApiKey();
      await _screenLookupAiClient.analyze(
        settings: settings,
        apiKey: apiKey,
        word: 'offer',
        context: 'Childcare providers can offer the specialized care needed.',
      );
      _showMessage('连接成功，模型能够返回结构化的本句义项。');
    } on ScreenLookupAiException catch (error) {
      _showMessage('连接测试失败：${error.message}');
    } catch (error) {
      debugPrint('AI connection test failed: $error');
      _showMessage('连接测试失败。');
    } finally {
      if (mounted) setState(() => _windowsScreenLookupAiSaving = false);
    }
  }

  Future<void> _handleWindowsWindowLifecycleEvent(String event) async {
    switch (event) {
      case 'showSettingsRequested':
        if (mounted) _showSettings();
        break;
      case 'hiddenToTray':
        await Future.wait<void>([
          _aggregateArticleController.stopPlayback(),
          ..._articleControllers.values.map(
            (controller) => controller.stopPlayback(),
          ),
        ]);
        break;
      case 'restoredFromTray':
        if (mounted) _scheduleWordRecordsRefresh();
        break;
      case 'trayNotificationShown':
        _windowsTrayNotificationShown = true;
        try {
          await widget.windowsAppSettings.saveTrayNotificationShown(true);
        } catch (error) {
          debugPrint('Tray notification state could not be saved: $error');
        }
        break;
    }
  }

  Future<void> _handleWindowsScreenLookupEvent(
    String event,
    Map<Object?, Object?> arguments,
  ) async {
    switch (event) {
      case 'lookupRequested':
        final text = arguments['text'];
        final x = arguments['x'];
        final y = arguments['y'];
        if (text is String && x is int && y is int) {
          await _lookupInScreenPopup(
            WindowsScreenLookupRequest(
              text: text,
              context: arguments['context'] is String
                  ? arguments['context'] as String
                  : '',
              x: x,
              y: y,
              usedClipboardFallback: arguments['usedClipboardFallback'] == true,
            ),
          );
        }
        break;
      case 'lookupUnavailable':
        final error = arguments['error'];
        final x = arguments['x'];
        final y = arguments['y'];
        if (x is int && y is int) {
          await _windowsScreenLookup.showMessage(
            title: error == 'permission'
                ? '需要辅助功能权限'
                : error == 'protected'
                    ? '此处不支持取词'
                    : '没有读取到选中文字',
            message: error == 'permission'
                ? '当前运行的 LumaLex 未获得辅助功能权限。若系统已显示开启，请移除旧条目，重新添加设置页“在 Finder 中显示当前应用”所定位的应用，开启权限后彻底退出并重开 LumaLex。'
                : error == 'protected'
                    ? '为保护隐私，LumaLex 不会读取密码输入框。'
                    : '请先在其他应用中选中一个单词或短语，再按取词快捷键。',
            x: x,
            y: y,
          );
        }
        break;
      case 'screenLookupClosed':
        _screenLookupRequest++;
        _screenLookupAiRequest++;
        _screenLookupContentSession?.close();
        _screenLookupContentSession = null;
        _screenLookupEntries = const [];
        _screenLookupQuery = null;
        _screenLookupContext = '';
        _screenLookupAiPayload = null;
        _screenLookupArticle = null;
        _screenLookupPinned = false;
        unawaited(_stopScreenLookupPlayback());
        break;
      case 'openInMain':
        final text = arguments['text'];
        if (text is String && text.trim().isNotEmpty && mounted) {
          _queryController.value = TextEditingValue(
            text: text.trim(),
            selection: TextSelection.collapsed(offset: text.trim().length),
          );
          await _openWordInLookup(text.trim());
        }
        break;
      case 'selectDictionary':
        final index = arguments['index'];
        if (index is int) {
          await _selectScreenLookupDictionary(index);
        }
        break;
      case 'selectDictionaryScope':
        final scopeCode = arguments['scopeCode'];
        if (scopeCode is int) {
          await _selectScreenLookupScope(scopeCode);
        }
        break;
      case 'playSound':
        final value = arguments['value'];
        if (value is String) {
          await _playScreenLookupSound(value);
        }
        break;
      case 'speak':
        final value = arguments['value'];
        if (value is String) {
          await _speakScreenLookupText(value);
        }
        break;
      case 'toggleFavorite':
        final query = _screenLookupQuery;
        if (query != null && query.isNotEmpty) {
          await _wordRecordsReady;
          await _toggleFavorite(
            query,
            articleHtml: _screenLookupArticle?.html,
          );
        }
        break;
      case 'pinChanged':
        _screenLookupPinned = arguments['pinned'] == true;
        break;
      case 'analyzeAi':
        await _analyzeCurrentScreenLookupWithAi();
        break;
    }
  }

  Future<void> _publishScreenLookupAiPayload(
    Map<String, Object?> payload,
  ) async {
    _screenLookupAiPayload = payload;
    try {
      await _windowsScreenLookup.updateAiResult(
        encodeScreenLookupAiPayload(payload),
        pending: payload['status'] == 'loading',
      );
    } on MissingPluginException catch (error) {
      debugPrint('Windows AI popup update is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint(
        'Windows AI popup update failed: ${error.code} ${error.message}',
      );
    }
  }

  Future<void> _analyzeCurrentScreenLookupWithAi() async {
    final query = _screenLookupQuery;
    final context = _screenLookupContext;
    if (query == null || query.isEmpty) return;
    if (!_screenLookupAiConfigured) {
      await _publishScreenLookupAiPayload(const <String, Object?>{
        'status': 'error',
        'message': '请先在主窗口的“设置 → AI 语境释义”中完成配置。',
      });
      return;
    }
    if (context.trim().isEmpty) {
      await _publishScreenLookupAiPayload(const <String, Object?>{
        'status': 'error',
        'message': '当前应用只提供了选中词，没有提供附近语境，因此无法可靠判断本句义项。',
      });
      return;
    }
    final request = ++_screenLookupAiRequest;
    await _publishScreenLookupAiPayload(<String, Object?>{
      'status': 'loading',
      'query': query,
    });
    try {
      final apiKey = await _loadWindowsScreenLookupAiApiKey();
      final result = await _screenLookupAiClient.analyze(
        settings: _savedScreenLookupAiSettings,
        apiKey: apiKey,
        word: query,
        context: context,
      );
      if (request != _screenLookupAiRequest ||
          query != _screenLookupQuery ||
          context != _screenLookupContext) {
        return;
      }
      await _publishScreenLookupAiPayload(<String, Object?>{
        'status': 'success',
        'query': query,
        ...result.toJson(),
      });
    } on ScreenLookupAiException catch (error) {
      if (request != _screenLookupAiRequest) return;
      await _publishScreenLookupAiPayload(<String, Object?>{
        'status': 'error',
        'message': error.message,
      });
    } catch (error) {
      debugPrint('Screen lookup AI analysis failed: $error');
      if (request != _screenLookupAiRequest) return;
      await _publishScreenLookupAiPayload(const <String, Object?>{
        'status': 'error',
        'message': 'AI 分析暂时失败，请稍后重试。',
      });
    }
  }

  Future<void> _lookupInScreenPopup(
    WindowsScreenLookupRequest lookup,
  ) async {
    final query = lookup.text.trim();
    if (query.isEmpty || query.length > 128) return;
    final request = ++_screenLookupRequest;
    _screenLookupContentSession?.close();
    _screenLookupContentSession = null;
    _screenLookupPinned = false;
    _screenLookupAiRequest++;
    _screenLookupAiPayload = null;
    try {
      await _windowsScreenLookup.showLoading(lookup);
      await Future.wait<void>([_libraryReady, _wordRecordsReady]);
      if (!mounted || request != _screenLookupRequest) return;
      final availableEntries = screenLookupEntriesInGroupOrder(
        _allAvailableEntries,
        _dictionaryGroupSnapshot.groups,
      );
      final selectedPath = _selectedMdxPath;
      final entries = availableEntries;
      if (entries.isEmpty) {
        await _windowsScreenLookup.showMessage(
          title: '没有可用词典',
          message: '请先在主窗口的词典页中启用至少一本本地词典。',
          x: lookup.x,
          y: lookup.y,
        );
        return;
      }
      _screenLookupEntries = entries;
      _screenLookupQuery = query;
      _screenLookupContext = lookup.context;
      _screenLookupX = lookup.x;
      _screenLookupY = lookup.y;
      _screenLookupScopeId ??= _activeDictionaryScopeId;
      var allowedIndexes = screenLookupIndexesForScope(
        entries,
        _dictionaryGroupSnapshot.groups,
        _screenLookupScopeId!,
      );
      if (allowedIndexes.isEmpty) {
        // A formerly selected group may have been removed or disabled.
        _screenLookupScopeId = DictionaryGroupScope.all;
        allowedIndexes = List<int>.generate(entries.length, (index) => index);
      }
      final preferredIndex = allowedIndexes.firstWhere(
        (index) => entries[index].mdxPath == selectedPath,
        orElse: () => allowedIndexes.first,
      );
      await _searchScreenLookupScope(
        request: request,
        query: query,
        allowedIndexes: allowedIndexes,
        preferredIndex: preferredIndex,
      );
    } on MissingPluginException catch (error) {
      debugPrint('Windows screen lookup popup is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint(
        'Windows screen lookup popup failed: ${error.code} ${error.message}',
      );
    } catch (error) {
      debugPrint('Windows screen lookup failed: $error');
      if (request == _screenLookupRequest) {
        await _windowsScreenLookup.showMessage(
          title: '取词失败',
          message: '暂时无法读取本地词典，请稍后再试。',
          x: lookup.x,
          y: lookup.y,
        );
      }
    }
  }

  Future<void> _searchScreenLookupScope({
    required int request,
    required String query,
    required List<int> allowedIndexes,
    required int preferredIndex,
  }) async {
    if (allowedIndexes.isEmpty) return;
    Article? matchedArticle;
    var matchedIndex = preferredIndex;
    for (final index in <int>[
      preferredIndex,
      ...allowedIndexes.where((index) => index != preferredIndex),
    ]) {
      List<Article> articles;
      try {
        articles = await _resolveArticles(_screenLookupEntries[index], query);
      } catch (_) {
        articles = const [];
      }
      if (!mounted || request != _screenLookupRequest) return;
      if (articles.isNotEmpty) {
        matchedArticle = articles.first;
        matchedIndex = index;
        break;
      }
    }
    await _renderScreenLookupDictionary(
      request: request,
      dictionaryIndex: matchedIndex,
      article: matchedArticle,
    );
  }

  Future<void> _selectScreenLookupScope(int scopeCode) async {
    final query = _screenLookupQuery;
    if (query == null || _screenLookupEntries.isEmpty) return;
    final groups = _dictionaryGroupSnapshot.groups;
    final String? scopeId;
    if (scopeCode == -1) {
      scopeId = DictionaryGroupScope.all;
    } else if (scopeCode == -2) {
      scopeId = DictionaryGroupScope.ungrouped;
    } else if (scopeCode >= 0 && scopeCode < groups.length) {
      scopeId = groups[scopeCode].id;
    } else {
      scopeId = null;
    }
    if (scopeId == null || scopeId == _screenLookupScopeId) return;
    final allowedIndexes = screenLookupIndexesForScope(
      _screenLookupEntries,
      groups,
      scopeId,
    );
    if (allowedIndexes.isEmpty) return;
    _screenLookupScopeId = scopeId;
    final request = ++_screenLookupRequest;
    _screenLookupContentSession?.close();
    _screenLookupContentSession = null;
    await _stopScreenLookupPlayback();
    await _searchScreenLookupScope(
      request: request,
      query: query,
      allowedIndexes: allowedIndexes,
      preferredIndex: allowedIndexes.contains(_screenLookupDictionaryIndex)
          ? _screenLookupDictionaryIndex
          : allowedIndexes.first,
    );
  }

  Future<void> _selectScreenLookupDictionary(int index) async {
    final query = _screenLookupQuery;
    if (query == null ||
        index < 0 ||
        index >= _screenLookupEntries.length ||
        index == _screenLookupDictionaryIndex) {
      return;
    }
    final allowedIndexes = screenLookupIndexesForScope(
      _screenLookupEntries,
      _dictionaryGroupSnapshot.groups,
      _screenLookupScopeId ?? DictionaryGroupScope.all,
    );
    if (!allowedIndexes.contains(index)) {
      final groupId = _screenLookupEntries[index].groupId;
      _screenLookupScopeId = groupId != null &&
              _dictionaryGroupSnapshot.groups
                  .any((group) => group.id == groupId)
          ? groupId
          : DictionaryGroupScope.ungrouped;
    }
    final request = ++_screenLookupRequest;
    _screenLookupDictionaryIndex = index;
    _screenLookupContentSession?.close();
    _screenLookupContentSession = null;
    await _stopScreenLookupPlayback();
    List<Article> articles;
    try {
      articles = await _resolveArticles(_screenLookupEntries[index], query);
    } catch (_) {
      articles = const [];
    }
    if (!mounted || request != _screenLookupRequest) return;
    await _renderScreenLookupDictionary(
      request: request,
      dictionaryIndex: index,
      article: articles.firstOrNull,
    );
  }

  Future<void> _renderScreenLookupDictionary({
    required int request,
    required int dictionaryIndex,
    required Article? article,
  }) async {
    final query = _screenLookupQuery;
    if (query == null ||
        dictionaryIndex < 0 ||
        dictionaryIndex >= _screenLookupEntries.length) {
      return;
    }
    final entry = _screenLookupEntries[dictionaryIndex];
    final session = await DictionaryContentServer.instance.openSession(
      engine: widget.engine,
      mdxPath: entry.mdxPath,
    );
    if (!mounted || request != _screenLookupRequest) {
      session.close();
      return;
    }
    _screenLookupDictionaryIndex = dictionaryIndex;
    _screenLookupArticle = article;
    final articleHtml = article?.html ??
        '''<div class="lumalex-screen-empty">
          <strong>“${const HtmlEscape(HtmlEscapeMode.element).convert(query)}”</strong>
          <span>未在这本词典中找到。可以从上方切换其他词典。</span>
        </div>''';
    final contextAvailable = _screenLookupContext.trim().isNotEmpty;
    final document = buildArticleDocument(
      _buildScreenLookupArticleHtml(
        query: query,
        entries: _screenLookupEntries,
        selectedIndex: dictionaryIndex,
        favorite: _isFavorite(query),
        pinned: _screenLookupPinned,
        contextAvailable: contextAvailable,
        aiAvailable: _screenLookupAiConfigured && contextAvailable,
        initialAiPayload: _screenLookupAiPayload == null
            ? null
            : encodeScreenLookupAiPayload(_screenLookupAiPayload!),
        articleHtml: articleHtml,
      ),
      localScriptCompatibilityEnabled: true,
      resourceBaseUrl: session.resourceBaseUri.toString(),
      includeNativeBridges: false,
      textScale: _textScale,
    );
    session.setDocument(document);
    _screenLookupContentSession?.close();
    _screenLookupContentSession = session;
    await _windowsScreenLookup.showArticle(
      uri: session.articleUri,
      x: _screenLookupX,
      y: _screenLookupY,
    );
  }

  String _buildScreenLookupArticleHtml({
    required String query,
    required List<DictionaryLibraryEntry> entries,
    required int selectedIndex,
    required bool favorite,
    required bool pinned,
    required bool contextAvailable,
    required bool aiAvailable,
    required String? initialAiPayload,
    required String articleHtml,
  }) {
    const elementEscape = HtmlEscape(HtmlEscapeMode.element);
    const attributeEscape = HtmlEscape(HtmlEscapeMode.attribute);
    final safeQuery = elementEscape.convert(query);
    final scopeId = _screenLookupScopeId ?? DictionaryGroupScope.all;
    final allowedIndexes = screenLookupIndexesForScope(
      entries,
      _dictionaryGroupSnapshot.groups,
      scopeId,
    );
    final dictionaryMenu = buildScreenLookupDictionaryMenu(
      entries: entries,
      groups: _dictionaryGroupSnapshot.groups,
      selectedIndex: selectedIndex,
      scopeId: scopeId,
    );
    final allowedIndexesJson = jsonEncode(allowedIndexes);
    final safeSelectedDictionary =
        elementEscape.convert(entries[selectedIndex].title);
    final scopeName = _dictionaryScopeName(scopeId);
    final safeScopeName = elementEscape.convert(scopeName);
    final safeScopeTitle = attributeEscape.convert('查词范围：$scopeName');
    final favoriteTitle = favorite ? '取消收藏' : '收藏到词汇本';
    final pinLabel = pinned ? '持续显示' : '自动关闭';
    final pinTitle =
        pinned ? '当前不会自动关闭；点击恢复为移出浮窗 5 秒后关闭' : '光标在浮窗内不会关闭；移出 5 秒后自动关闭';
    final ttsResolver = dictionaryTextToSpeechResolverJavascript();
    final aiButton = aiAvailable
        ? '''<button id="lumalex-screen-ai-button" class="lumalex-screen-ai-button"
      title="让 AI 根据附近语境判断本句义项"
      onclick="lumalexAnalyzeWithAi(this)">
      <span aria-hidden="true">✦</span><span>AI</span>
    </button>'''
        : '';
    final compatibilityNotice = contextAvailable
        ? ''
        : '''<div class="lumalex-screen-compatibility-note">
      兼容复制模式：仅词典查词，无 AI 语境释义
    </div>''';
    final initialAiScript = initialAiPayload == null
        ? ''
        : "lumalexApplyAiPayload('$initialAiPayload');";
    return '''
<style>
  #lumalex-screen-lookup-toolbar {
    all: initial !important;
    position: sticky !important;
    top: 0 !important;
    z-index: 2147483647 !important;
    display: block !important;
    padding: 7px 9px 9px 14px !important;
    box-sizing: border-box !important;
    background: rgba(248, 250, 250, .97) !important;
    border-bottom: 1px solid #d5e1e1 !important;
    box-shadow: 0 4px 16px rgba(20, 43, 45, .08) !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
    color: #172323 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-top {
    all: initial !important;
    display: flex !important;
    align-items: center !important;
    gap: 8px !important;
    font-family: inherit !important;
    cursor: grab !important;
    touch-action: none !important;
    user-select: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-top.dragging {
    cursor: grabbing !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-title {
    all: initial !important;
    display: flex !important;
    flex: 1 !important;
    min-width: 0 !important;
    flex-direction: column !important;
    font-family: inherit !important;
  }
  #lumalex-screen-lookup-toolbar strong,
  #lumalex-screen-lookup-toolbar small {
    all: initial !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    white-space: nowrap !important;
    font-family: inherit !important;
  }
  #lumalex-screen-lookup-toolbar strong {
    color: #172323 !important;
    font-size: 16px !important;
    font-weight: 700 !important;
  }
  #lumalex-screen-lookup-toolbar button {
    all: initial !important;
    min-width: 44px !important;
    height: 44px !important;
    padding: 0 11px !important;
    box-sizing: border-box !important;
    border: 1px solid #b7c8c8 !important;
    border-radius: 11px !important;
    background: white !important;
    color: #1d3839 !important;
    cursor: pointer !important;
    display: grid !important;
    place-items: center !important;
    font: 600 13px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  /* Decorative descendants must not reset the button's pointer cursor or
     receive hits instead of their owning control. */
  #lumalex-screen-lookup-toolbar button * {
    cursor: inherit !important;
    pointer-events: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-title,
  #lumalex-screen-lookup-toolbar .lumalex-screen-title * {
    cursor: inherit !important;
  }
  #lumalex-screen-lookup-toolbar button.active {
    background: #d9f3f4 !important;
    border-color: #087e87 !important;
    color: #087e87 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-ai-button {
    display: flex !important;
    grid-auto-flow: column !important;
    gap: 4px !important;
    color: #6952b5 !important;
    border-color: #c9c0ea !important;
    background: #f7f4ff !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-ai-button:disabled {
    cursor: wait !important;
    opacity: .62 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite {
    padding: 0 !important;
    border-color: transparent !important;
    background: transparent !important;
    color: #536262 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite:hover {
    background: rgba(8, 126, 135, .09) !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite.active {
    border-color: transparent !important;
    background: transparent !important;
    color: #f2a51a !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite svg {
    all: initial !important;
    display: block !important;
    width: 30px !important;
    height: 30px !important;
    fill: currentColor !important;
    color: inherit !important;
    cursor: inherit !important;
    pointer-events: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite .filled,
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite.active .outline {
    display: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-favorite.active .filled {
    display: block !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-row {
    all: initial !important;
    display: flex !important;
    align-items: center !important;
    gap: 8px !important;
    margin-top: 7px !important;
    font: 600 12px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
    color: #657474 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-label {
    all: initial !important;
    display: flex !important;
    flex-direction: column !important;
    flex: 0 0 auto !important;
    width: 74px !important;
    font: 600 12px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
    color: #657474 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-label small {
    all: initial !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    white-space: nowrap !important;
    font: 500 10px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
    color: #819090 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-controls {
    all: initial !important;
    display: flex !important;
    flex: 1 1 auto !important;
    align-items: center !important;
    gap: 6px !important;
    min-width: 0 !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-controls button {
    height: 42px !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-step {
    flex: 0 0 42px !important;
    min-width: 42px !important;
    padding: 0 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-step svg {
    all: initial !important;
    display: block !important;
    width: 20px !important;
    height: 20px !important;
    margin: auto !important;
    cursor: inherit !important;
    pointer-events: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-step svg path {
    fill: none !important;
    stroke: #1d3839 !important;
    stroke-width: 3 !important;
    stroke-linecap: round !important;
    stroke-linejoin: round !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-step:disabled {
    opacity: .38 !important;
    cursor: default !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-wrap {
    all: initial !important;
    position: relative !important;
    display: block !important;
    flex: 1 1 auto !important;
    min-width: 0 !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-trigger {
    display: flex !important;
    justify-content: space-between !important;
    width: 100% !important;
    height: 42px !important;
    min-width: 0 !important;
    gap: 9px !important;
    padding: 0 11px !important;
    font-size: 14px !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-trigger:focus-visible {
    border-color: #087e87 !important;
    box-shadow: 0 0 0 2px rgba(8, 126, 135, .15) !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-trigger .name {
    all: initial !important;
    flex: 1 1 auto !important;
    min-width: 0 !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
    white-space: nowrap !important;
    color: #1d3839 !important;
    font: 600 14px/1.3 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-trigger .chevron {
    all: initial !important;
    flex: 0 0 auto !important;
    color: #536262 !important;
    font: 700 14px/1 'Segoe UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-menu {
    all: initial !important;
    position: absolute !important;
    z-index: 10 !important;
    top: calc(100% + 5px) !important;
    left: 0 !important;
    right: 0 !important;
    display: block !important;
    max-height: min(310px, calc(100vh - 145px)) !important;
    overflow-y: auto !important;
    overscroll-behavior: contain !important;
    box-sizing: border-box !important;
    padding: 5px !important;
    border: 1px solid #b7c8c8 !important;
    border-radius: 11px !important;
    background: white !important;
    box-shadow: 0 10px 26px rgba(20, 43, 45, .2) !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-menu[hidden] {
    display: none !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-heading {
    all: initial !important;
    display: flex !important;
    position: sticky !important;
    top: -5px !important;
    z-index: 1 !important;
    width: 100% !important;
    min-width: 0 !important;
    min-height: 38px !important;
    height: auto !important;
    box-sizing: border-box !important;
    justify-content: space-between !important;
    align-items: center !important;
    padding: 7px 9px !important;
    border: 0 !important;
    border-radius: 6px !important;
    background: #edf4f4 !important;
    color: #566b6b !important;
    font: 700 11px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-heading.selected {
    background: #d9f3f4 !important;
    color: #087e87 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-menu-heading span {
    all: initial !important;
    color: inherit !important;
    font: 500 10px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-menu .lumalex-screen-menu-item {
    display: block !important;
    width: 100% !important;
    min-width: 0 !important;
    height: auto !important;
    min-height: 42px !important;
    padding: 8px 10px !important;
    text-align: left !important;
    overflow-wrap: anywhere !important;
    border: 0 !important;
    border-radius: 7px !important;
    font-size: 13px !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-menu .lumalex-screen-menu-item:hover,
  #lumalex-screen-lookup-toolbar .lumalex-screen-dictionary-menu .lumalex-screen-menu-item.selected {
    background: #d9f3f4 !important;
    color: #087e87 !important;
  }
  #lumalex-screen-lookup-toolbar .lumalex-screen-compatibility-note {
    all: initial !important;
    display: block !important;
    margin-top: 6px !important;
    color: #718080 !important;
    font: 500 10px/1.35 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card {
    all: initial !important;
    display: none !important;
    margin: 10px 12px !important;
    padding: 14px 16px !important;
    box-sizing: border-box !important;
    border: 1px solid #cfc7ed !important;
    border-radius: 14px !important;
    background: linear-gradient(135deg, #fbf9ff, #f2f8ff) !important;
    box-shadow: 0 4px 14px rgba(63, 53, 102, .09) !important;
    color: #242033 !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card.visible { display: block !important; }
  #lumalex-screen-ai-card .ai-header {
    all: initial !important;
    display: flex !important;
    align-items: center !important;
    gap: 7px !important;
    margin-bottom: 9px !important;
    color: #6952b5 !important;
    font: 700 14px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-confidence {
    all: initial !important;
    margin-left: auto !important;
    padding: 2px 7px !important;
    border-radius: 999px !important;
    background: #e9e3fb !important;
    color: #5c479f !important;
    font: 600 10px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-status,
  #lumalex-screen-ai-card .ai-line,
  #lumalex-screen-ai-card .ai-meaning,
  #lumalex-screen-ai-card .ai-evidence,
  #lumalex-screen-ai-card .ai-note {
    all: initial !important;
    display: block !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-status {
    color: #5d5969 !important;
    font-size: 13px !important;
    line-height: 1.5 !important;
  }
  #lumalex-screen-ai-card .ai-line {
    display: flex !important;
    align-items: baseline !important;
    gap: 8px !important;
    margin-bottom: 5px !important;
  }
  #lumalex-screen-ai-card .ai-lemma {
    all: initial !important;
    color: #282039 !important;
    font: 700 17px 'Segoe UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-pos {
    all: initial !important;
    color: #6952b5 !important;
    font: 600 12px 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-meaning {
    margin: 4px 0 !important;
    color: #172323 !important;
    font-size: 16px !important;
    font-weight: 650 !important;
    line-height: 1.45 !important;
  }
  #lumalex-screen-ai-card .ai-english {
    all: initial !important;
    display: block !important;
    color: #526060 !important;
    font: 400 12px/1.45 'Segoe UI', sans-serif !important;
  }
  #lumalex-screen-ai-card .ai-evidence {
    margin-top: 8px !important;
    padding-left: 10px !important;
    border-left: 3px solid #9c8bda !important;
    color: #4f4960 !important;
    font-size: 12px !important;
    font-style: italic !important;
    line-height: 1.45 !important;
  }
  #lumalex-screen-ai-card .ai-note {
    margin-top: 7px !important;
    color: #78644f !important;
    font-size: 11px !important;
    line-height: 1.4 !important;
  }
  .lumalex-screen-empty {
    min-height: 260px !important;
    display: flex !important;
    flex-direction: column !important;
    align-items: center !important;
    justify-content: center !important;
    gap: 10px !important;
    padding: 28px !important;
    box-sizing: border-box !important;
    font-family: 'Segoe UI', 'Microsoft YaHei UI', sans-serif !important;
    color: #506060 !important;
    text-align: center !important;
  }
  .lumalex-screen-empty strong { color: #172323 !important; }
</style>
<div id="lumalex-screen-lookup-toolbar">
  <div class="lumalex-screen-top">
    <span class="lumalex-screen-title" title="按住顶部空白处拖动浮窗"><strong>$safeQuery</strong></span>
    $aiButton
    <button class="lumalex-screen-favorite${favorite ? ' active' : ''}"
      aria-pressed="${favorite ? 'true' : 'false'}"
      aria-label="${attributeEscape.convert(favoriteTitle)}"
      title="${attributeEscape.convert(favoriteTitle)}"
      onclick="lumalexToggleFavorite(this)">
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path class="outline" d="M22 9.24l-7.19-.62L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.63-7.03L22 9.24zm-10 6.16-3.76 2.27 1-4.28-3.32-2.88 4.38-.38L12 6.1l1.71 4.04 4.38.38-3.32 2.88 1 4.28L12 15.4z"></path>
        <path class="filled" d="M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"></path>
      </svg>
    </button>
    <button class="${pinned ? 'active' : ''}"
      aria-pressed="${pinned ? 'true' : 'false'}"
      title="${attributeEscape.convert(pinTitle)}"
      onclick="lumalexTogglePin(this)">$pinLabel</button>
    <button title="在主窗口打开" onclick="chrome.webview.postMessage('openMain')">主窗口</button>
    <button title="关闭" onclick="chrome.webview.postMessage('close')">×</button>
  </div>
  <div class="lumalex-screen-dictionary-row">
    <span class="lumalex-screen-dictionary-label">
      <span>范围</span><small title="$safeScopeTitle">$safeScopeName</small>
    </span>
    <span id="lumalex-screen-dictionary-controls" class="lumalex-screen-dictionary-controls"
      data-selected-index="$selectedIndex">
      <button type="button" class="lumalex-screen-step" aria-label="上一本词典"
        title="上一本词典" onclick="lumalexStepDictionary(-1)"
        ${allowedIndexes.isNotEmpty && selectedIndex == allowedIndexes.first ? 'disabled' : ''}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 6 L9 12 L15 18"/></svg>
      </button>
      <span class="lumalex-screen-menu-wrap">
        <button type="button" id="lumalex-screen-dictionary-trigger"
          class="lumalex-screen-menu-trigger" aria-haspopup="listbox"
          aria-expanded="false" aria-controls="lumalex-screen-dictionary-menu"
          title="点击按分组选择词典；触摸左右滑动切换"
          onclick="lumalexToggleDictionaryMenu()">
          <span class="name">$safeSelectedDictionary</span>
          <span class="chevron" aria-hidden="true">▾</span>
        </button>
        <span id="lumalex-screen-dictionary-menu" class="lumalex-screen-dictionary-menu"
          role="listbox" aria-label="按分组选择词典" hidden>
          $dictionaryMenu
        </span>
      </span>
      <button type="button" class="lumalex-screen-step" aria-label="下一本词典"
        title="下一本词典" onclick="lumalexStepDictionary(1)"
        ${allowedIndexes.isNotEmpty && selectedIndex == allowedIndexes.last ? 'disabled' : ''}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6 L15 12 L9 18"/></svg>
      </button>
    </span>
  </div>
  $compatibilityNotice
</div>
<section id="lumalex-screen-ai-card" aria-live="polite">
  <div class="ai-header"><span aria-hidden="true">✦</span>
    <span>AI 本句义项</span><span id="lumalex-ai-confidence" class="ai-confidence"></span>
  </div>
  <div id="lumalex-ai-status" class="ai-status"></div>
  <div id="lumalex-ai-result" hidden>
    <div class="ai-line"><span id="lumalex-ai-lemma" class="ai-lemma"></span>
      <span id="lumalex-ai-pos" class="ai-pos"></span></div>
    <div id="lumalex-ai-chinese" class="ai-meaning"></div>
    <div id="lumalex-ai-english" class="ai-english"></div>
    <div id="lumalex-ai-evidence" class="ai-evidence"></div>
    <div id="lumalex-ai-note" class="ai-note"></div>
  </div>
</section>
<script>
  (function () {
    const handle = document.querySelector('#lumalex-screen-lookup-toolbar .lumalex-screen-top');
    if (!handle) return;
    let pointerId = null;
    let pointerType = 'mouse';
    let originX = 0;
    let originY = 0;
    let scale = 1;
    let lastX = 0;
    let lastY = 0;
    function move(event) {
      if (pointerId === null || event.pointerId !== pointerId) return;
      const x = Math.round((event.screenX - originX) * scale);
      const y = Math.round((event.screenY - originY) * scale);
      if (x === lastX && y === lastY) return;
      lastX = x;
      lastY = y;
      chrome.webview.postMessage('drag:move:' + x + ':' + y);
      event.preventDefault();
    }
    function finish(event) {
      if (pointerId === null || (event && event.pointerId !== pointerId)) return;
      if (event && event.type === 'pointerup') move(event);
      pointerId = null;
      handle.classList.remove('dragging');
      chrome.webview.postMessage('drag:end:' + (pointerType === 'mouse' ? 'mouse' : 'touch'));
      if (event) {
        try { handle.releasePointerCapture(event.pointerId); } catch (_) {}
      }
    }
    handle.addEventListener('pointerdown', function (event) {
      if (pointerId !== null || !event.isPrimary ||
          (event.pointerType === 'mouse' && event.button !== 0) ||
          event.target.closest('button')) return;
      pointerId = event.pointerId;
      pointerType = event.pointerType;
      originX = event.screenX;
      originY = event.screenY;
      scale = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lumalex ? 1 : (window.devicePixelRatio || 1);
      lastX = 0;
      lastY = 0;
      handle.classList.add('dragging');
      try { handle.setPointerCapture(event.pointerId); } catch (_) {}
      chrome.webview.postMessage('drag:start');
      event.preventDefault();
    });
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', finish);
    handle.addEventListener('pointercancel', finish);
    handle.addEventListener('lostpointercapture', finish);
    document.addEventListener('pointerleave', function (event) {
      if (pointerId !== null && !handle.hasPointerCapture(pointerId)) finish(event);
    });
    window.addEventListener('blur', function () { finish(null); });
  })();
  function lumalexTogglePin(button) {
    const pinned = button.getAttribute('aria-pressed') !== 'true';
    button.setAttribute('aria-pressed', pinned ? 'true' : 'false');
    button.classList.toggle('active', pinned);
    button.textContent = pinned ? '持续显示' : '自动关闭';
    button.title = pinned
      ? '当前不会自动关闭；点击恢复为移出浮窗 5 秒后关闭'
      : '光标在浮窗内不会关闭；移出 5 秒后自动关闭';
    chrome.webview.postMessage('pin');
  }
  function lumalexToggleFavorite(button) {
    const saved = button.getAttribute('aria-pressed') !== 'true';
    button.setAttribute('aria-pressed', saved ? 'true' : 'false');
    button.classList.toggle('active', saved);
    button.title = saved ? '取消收藏' : '收藏到词汇本';
    button.setAttribute('aria-label', button.title);
    chrome.webview.postMessage('toggleFavorite');
  }
  function lumalexAnalyzeWithAi(button) {
    if (button) button.disabled = true;
    lumalexApplyAiState({status: 'loading'});
    chrome.webview.postMessage('analyzeAi');
  }
  function lumalexAiText(id, value) {
    const element = document.getElementById(id);
    if (element) element.textContent = value || '';
  }
  function lumalexApplyAiState(state) {
    const card = document.getElementById('lumalex-screen-ai-card');
    const status = document.getElementById('lumalex-ai-status');
    const result = document.getElementById('lumalex-ai-result');
    const button = document.getElementById('lumalex-screen-ai-button');
    if (!card || !status || !result) return;
    card.classList.add('visible');
    const mode = state && state.status ? state.status : 'error';
    if (mode === 'loading') {
      status.textContent = '正在结合附近语境判断本句义项…';
      result.hidden = true;
      if (button) button.disabled = true;
      return;
    }
    if (button) button.disabled = false;
    if (mode === 'error') {
      status.textContent = state && state.message
        ? state.message : 'AI 分析暂时失败。';
      result.hidden = true;
      lumalexAiText('lumalex-ai-confidence', '');
      return;
    }
    status.textContent = '';
    result.hidden = false;
    lumalexAiText('lumalex-ai-lemma', state.lemma || state.query || '');
    lumalexAiText('lumalex-ai-pos', state.partOfSpeech || '');
    lumalexAiText('lumalex-ai-chinese', state.chineseMeaning || '');
    lumalexAiText('lumalex-ai-english', state.englishMeaning || '');
    lumalexAiText(
      'lumalex-ai-evidence',
      state.evidence ? '语境依据：“' + state.evidence + '”' : ''
    );
    lumalexAiText('lumalex-ai-note', state.ambiguityNote || '');
    const confidence = state.confidence === 'high' ? '高可信度'
      : state.confidence === 'medium' ? '中等可信度'
      : state.confidence === 'low' ? '低可信度' : '';
    lumalexAiText('lumalex-ai-confidence', confidence);
  }
  window.lumalexApplyAiPayload = function (payload) {
    try {
      const bytes = Uint8Array.from(atob(payload), function (character) {
        return character.charCodeAt(0);
      });
      lumalexApplyAiState(JSON.parse(new TextDecoder().decode(bytes)));
    } catch (_) {
      lumalexApplyAiState({status: 'error', message: '无法显示 AI 分析结果。'});
    }
  };
  $initialAiScript
  let lumalexSuppressMenuClick = false;
  function lumalexCloseDictionaryMenu() {
    const menu = document.getElementById('lumalex-screen-dictionary-menu');
    const trigger = document.getElementById('lumalex-screen-dictionary-trigger');
    if (!menu || !trigger) return;
    menu.hidden = true;
    trigger.setAttribute('aria-expanded', 'false');
  }
  function lumalexToggleDictionaryMenu() {
    if (lumalexSuppressMenuClick) {
      lumalexSuppressMenuClick = false;
      return;
    }
    const menu = document.getElementById('lumalex-screen-dictionary-menu');
    const trigger = document.getElementById('lumalex-screen-dictionary-trigger');
    if (!menu || !trigger) return;
    const opening = menu.hidden;
    menu.hidden = !opening;
    trigger.setAttribute('aria-expanded', String(opening));
    if (opening) {
      const selected = menu.querySelector('.lumalex-screen-menu-item.selected');
      if (selected) selected.scrollIntoView({block: 'nearest'});
    }
  }
  function lumalexSelectDictionary(value) {
    const index = Number(value);
    if (!Number.isInteger(index) || index < 0 || index >= ${entries.length}) return;
    lumalexCloseDictionaryMenu();
    chrome.webview.postMessage('dictionary:' + index);
  }
  function lumalexSelectScope(scopeCode) {
    lumalexCloseDictionaryMenu();
    chrome.webview.postMessage('scope:' + scopeCode);
  }
  function lumalexStepDictionary(step) {
    const controls = document.getElementById('lumalex-screen-dictionary-controls');
    if (!controls) return;
    const current = Number(controls.dataset.selectedIndex);
    if (!Number.isInteger(current)) return;
    const allowed = $allowedIndexesJson;
    const position = allowed.indexOf(current);
    if (position < 0) return;
    const nextPosition = Math.max(0, Math.min(allowed.length - 1, position + step));
    if (nextPosition !== position) lumalexSelectDictionary(allowed[nextPosition]);
  }
  (function () {
    const trigger = document.getElementById('lumalex-screen-dictionary-trigger');
    const menu = document.getElementById('lumalex-screen-dictionary-menu');
    if (!trigger || !menu) return;
    let pointerId = null;
    let startX = 0;
    function finish(event, cancelled) {
      if (pointerId === null || event.pointerId !== pointerId) return;
      const distance = event.clientX - startX;
      pointerId = null;
      if (!cancelled && Math.abs(distance) >= 34) {
        lumalexSuppressMenuClick = true;
        lumalexStepDictionary(distance < 0 ? 1 : -1);
        setTimeout(function () { lumalexSuppressMenuClick = false; }, 400);
      }
    }
    trigger.addEventListener('pointerdown', function (event) {
      if (event.pointerType === 'mouse') return;
      pointerId = event.pointerId;
      startX = event.clientX;
      try { trigger.setPointerCapture(event.pointerId); } catch (_) {}
    });
    trigger.addEventListener('pointerup', function (event) {
      finish(event, false);
    });
    trigger.addEventListener('pointercancel', function (event) {
      finish(event, true);
    });
    trigger.addEventListener('keydown', function (event) {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      lumalexStepDictionary(event.key === 'ArrowRight' ? 1 : -1);
    });
    document.addEventListener('pointerdown', function (event) {
      if (!menu.contains(event.target) && !trigger.contains(event.target)) {
        lumalexCloseDictionaryMenu();
      }
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && !menu.hidden) {
        lumalexCloseDictionaryMenu();
        trigger.focus();
      }
    });
  })();
  $ttsResolver
  document.documentElement.addEventListener('pointerenter', function () {
    chrome.webview.postMessage('pointer:inside');
  });
  document.documentElement.addEventListener('pointerleave', function () {
    chrome.webview.postMessage('pointer:outside');
  });
  document.addEventListener('pointerdown', function () {
    chrome.webview.postMessage('interact');
  }, {passive: true});
  document.addEventListener('click', function (event) {
    const rawTarget = event.target;
    const target = rawTarget && typeof rawTarget.closest === 'function'
      ? rawTarget : rawTarget && rawTarget.parentElement;
    const tts = target && target.closest
      ? target.closest(lumalexDictionaryTtsSelector) : null;
    if (tts) {
      event.preventDefault();
      event.stopImmediatePropagation();
      const request = lumalexDictionaryTtsRequest(tts);
      if (request) {
        chrome.webview.postMessage(
          'speak:' + encodeURIComponent(JSON.stringify(request))
        );
      }
      return;
    }
    const link = target && target.closest ? target.closest('[href]') : null;
    const href = link ? link.getAttribute('href') : null;
    if (!href || !/^sound:/i.test(href)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    chrome.webview.postMessage('playSound:' + encodeURIComponent(href));
  }, true);
</script>
$articleHtml
''';
  }

  Future<void> _playScreenLookupSound(String encodedValue) async {
    final article = _screenLookupArticle;
    if (article == null) return;
    String rawUri;
    try {
      rawUri = Uri.decodeComponent(encodedValue);
    } on FormatException {
      return;
    }
    final resourcePath = dictionarySoundResourcePath(rawUri);
    if (resourcePath == null) return;
    final request = ++_screenLookupAudioRequest;
    try {
      await _screenLookupTextToSpeech.stop();
      final resource = await widget.engine.readResource(
        resourcePath,
        maxBytes: _maximumScreenLookupAudioBytes,
        mdxPath: article.mdxPath,
      );
      if (!mounted ||
          request != _screenLookupAudioRequest ||
          resource == null) {
        return;
      }
      final player = _screenLookupAudioPlayer ??= AudioPlayer();
      if (player.playing) {
        await player.pause();
      }
      await _removeScreenLookupAudioCache();
      final directory = await Directory.systemTemp.createTemp(
        'lumalex_screen_lookup_audio_',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'pronunciation.${_screenLookupAudioExtension(resourcePath)}',
      );
      await file.writeAsBytes(resource.bytes, flush: true);
      if (!mounted || request != _screenLookupAudioRequest) {
        await directory.delete(recursive: true);
        return;
      }
      _screenLookupAudioDirectory = directory;
      await player.setFilePath(file.path, initialPosition: Duration.zero);
      if (!mounted || request != _screenLookupAudioRequest) return;
      await Future<void>.delayed(_windowsScreenLookupAudioDelay);
      if (!mounted || request != _screenLookupAudioRequest) return;
      unawaited(
        player.play().catchError((Object error) {
          debugPrint('Screen lookup audio playback failed: $error');
        }),
      );
    } catch (error) {
      debugPrint('Screen lookup audio setup failed: $error');
    }
  }

  Future<void> _speakScreenLookupText(String encodedValue) async {
    String decoded;
    try {
      decoded = Uri.decodeComponent(encodedValue);
    } on FormatException {
      return;
    }
    Object? request;
    try {
      request = jsonDecode(decoded);
    } on FormatException {
      return;
    }
    if (request is! Map) return;
    final text = request['text'];
    final locale = request['locale'];
    if (text is! String || locale is! String) return;
    _screenLookupAudioRequest++;
    try {
      await _screenLookupAudioPlayer?.stop();
      await _removeScreenLookupAudioCache();
      await _screenLookupTextToSpeech.speak(text, locale: locale);
    } catch (error) {
      debugPrint('Screen lookup text-to-speech failed: $error');
    }
  }

  Future<void> _stopScreenLookupPlayback() async {
    _screenLookupAudioRequest++;
    try {
      await _screenLookupAudioPlayer?.stop();
    } catch (error) {
      debugPrint('Screen lookup audio stop failed: $error');
    }
    try {
      await _screenLookupTextToSpeech.stop();
    } catch (error) {
      debugPrint('Screen lookup speech stop failed: $error');
    }
    await _removeScreenLookupAudioCache();
  }

  Future<void> _removeScreenLookupAudioCache() async {
    final directory = _screenLookupAudioDirectory;
    _screenLookupAudioDirectory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (!mounted) return;
    final contentServer = DictionaryContentServer.instance;
    final cachedResourceBytes = contentServer.cachedResourceBytes;
    final cachedResourceCount = contentServer.cachedResourceCount;
    contentServer.releaseCachedResources();
    ReaderDiagnostics.instance.record(
      'memory-pressure',
      data: {
        'platform': Platform.operatingSystem,
        'cachedResourceBytesReleased': cachedResourceBytes,
        'cachedResourceCountReleased': cachedResourceCount,
        if (_selectedMdxPath != null) 'selectedDictionary': _selectedMdxPath,
        'readerCount': _retainedReaderPaths.length,
      },
    );
    final selectedPath = _selectedMdxPath;
    if (selectedPath != null) {
      unawaited(
        _articleControllers[selectedPath]?.releaseTransientResources() ??
            Future.value(),
      );
    }
    _setMaximumRetainedReaders(
      _readerPlatformPolicy.memoryPressureRetainedReaders,
    );
  }

  Future<void> _loadAndroidReaderMemoryProfile() async {
    final profile = await AndroidReaderMemory.readProfile();
    if (!mounted || profile == null) return;
    _androidReaderMemoryProfile = profile;
    _restoreAndroidReaderRetentionLimit();
  }

  void _restoreAndroidReaderRetentionLimit() {
    final profile = _androidReaderMemoryProfile;
    if (!mounted || profile == null) return;
    _setMaximumRetainedReaders(
      _readerPlatformPolicy.retainedReadersForMemory(
        memoryClassMb: profile.memoryClassMb,
        isLowRamDevice: profile.isLowRamDevice,
      ),
    );
  }

  void _setMaximumRetainedReaders(int requestedLimit) {
    if (!mounted) return;
    final nextLimit = requestedLimit.clamp(1, 5).toInt();
    if (nextLimit == _maximumRetainedReaders) return;
    _rememberCurrentReaderPosition();
    final previousLimit = _maximumRetainedReaders;
    setState(() {
      _maximumRetainedReaders = nextLimit;
      _retainedReaderPaths = _adoptRetainedReaderPaths(
        trimRetainedReaderLru(
          retainedLruPaths: _retainedReaderPaths,
          selectedPath: _selectedMdxPath,
          maximumReaders: nextLimit,
        ),
      );
    });
    final selected = _selectedMdxPath;
    if (nextLimit > previousLimit &&
        selected != null &&
        _readerPlatformPolicy.preloadAdjacentDictionaryReader) {
      _preloadNextDictionaryReader(selected);
    }
  }

  Future<void> _recoverReadersAfterForeground({
    required Duration backgroundDuration,
  }) async {
    var serverRecovery = DictionaryContentServerRecovery.healthy;
    Object? serverRecoveryError;
    try {
      serverRecovery =
          await DictionaryContentServer.instance.recoverAfterForeground();
    } catch (error) {
      serverRecoveryError = error;
      debugPrint(
          'Dictionary content server foreground recovery failed: $error');
    }
    ReaderDiagnostics.instance.record(
      'application-foreground-recovery',
      data: {
        'backgroundMilliseconds': backgroundDuration.inMilliseconds,
        'serverRecovery': serverRecovery.name,
        'serverRecoveryFailed': serverRecoveryError != null,
      },
    );
    if (!mounted) return;
    // iOS keeps only the selected reader alive. Reloading invisible WebViews
    // after a lock/unlock event can briefly make several large documents live
    // at once, which is precisely when the OS is most likely to kill the app.
    final selectedPath = _selectedMdxPath;
    if (selectedPath == null || !_retainedReaderPaths.contains(selectedPath)) {
      return;
    }
    await _articleControllers[selectedPath]?.recoverAfterForeground(
      forceReload:
          serverRecovery == DictionaryContentServerRecovery.restarted ||
              serverRecoveryError != null,
    );
  }

  Future<void> _lookup(
    String rawQuery, {
    String? preferredMdxPath,
    String? initialAnchor,
    double? initialScrollOffset,
  }) async {
    final lookupTimer = Stopwatch()..start();
    // Allocate the request before any asynchronous dictionary restoration so
    // clearing the field or submitting another word cancels this whole path.
    final request = ++_lookupRequest;
    _lookupCorrectionTimer?.cancel();
    _lookupCorrectionTimer = null;
    // A person waiting for a definition always wins over disposable index
    // migration. Rust also cancels a build already in progress.
    _indexMigrationDelay?.cancel();
    _indexMigrationDelay = null;
    final query = rawQuery.trim();
    _rememberCurrentReaderPosition();
    if (query.isEmpty) {
      setState(() {
        _articlesByDictionary = const {};
        _readerQuery = '';
        _articleAnchor = null;
        _articleScrollOffset = null;
        _isSearching = false;
      });
      return;
    }
    _dictionaryWarmupDelay?.cancel();
    _dictionaryWarmupDelay = null;
    _dictionaryWarmupGeneration++;
    _readerWarmupDelay?.cancel();
    _readerWarmupDelay = null;
    if (_readerPlatformPolicy.aggregateDictionaryResults &&
        _hasPendingEnabledDictionary) {
      setState(() {
        _readerQuery = query;
        _suggestions = const [];
        _selectedSuggestionIndex = -1;
        _lookupCorrection = null;
        _isSearching = true;
      });
      await _prepareEnabledDictionariesForAggregateLookup();
      if (!mounted || request != _lookupRequest) return;
    }
    final dictionaries = _availableEntries;
    if (dictionaries.isEmpty) {
      setState(() => _isSearching = false);
      _showMessage(
        _supportsDictionaryGroups &&
                _activeDictionaryScopeId != DictionaryGroupScope.all
            ? '当前分组没有已启用且可访问的词典。请切换分组或前往词典页调整。'
            : '请先在词典库中启用至少一本词典。',
      );
      return;
    }

    unawaited(_wordRecordsReady.then((_) => _recordHistory(query)));
    final availablePaths = dictionaries.map((entry) => entry.mdxPath).toSet();
    final requestedPreferred = preferredMdxPath ?? _selectedMdxPath;
    final preferred = availablePaths.contains(requestedPreferred)
        ? requestedPreferred!
        : dictionaries.first.mdxPath;
    final cachedResults = <String, List<Article>>{};
    for (final entry in dictionaries) {
      final cached = _lookupResultCache.get(entry.mdxPath, query);
      if (cached != null) {
        cachedResults[entry.mdxPath] = cached;
      }
    }
    final resolvedResults = <String, List<Article>>{...cachedResults};
    setState(() {
      // Keep the current article visible while an uncached word is resolved.
      // Once the preferred result arrives, the persistent web view swaps its
      // document instead of being destroyed behind a blocking spinner.
      _articlesByDictionary = {...cachedResults};
      _selectedMdxPath = preferred;
      _readerQuery = query;
      _retainedReaderPaths = _adoptRetainedReaderPaths([preferred]);
      _articleAnchor = initialAnchor;
      _articleScrollOffset = initialScrollOffset;
      _suggestions = const [];
      _selectedSuggestionIndex = -1;
      _lookupCorrection = null;
      _isSearching = cachedResults.length != dictionaries.length;
    });

    Future<MapEntry<String, List<Article>>> resolveEntry(
      DictionaryLibraryEntry entry,
    ) async {
      List<Article> articles;
      try {
        articles = await _resolveArticles(entry, query);
      } catch (_) {
        articles = const [];
      }
      _lookupResultCache.put(entry.mdxPath, query, articles);
      resolvedResults[entry.mdxPath] = articles;
      // Publish results independently so the selected dictionary never waits
      // for every enabled source. Each newly available background result also
      // gets another chance to enter the bounded reader preload queue. Without
      // this, the first preload attempt can run before a slower MDX lookup has
      // finished and that dictionary would load only after the user selects it.
      if (mounted && request == _lookupRequest) {
        setState(() {
          _articlesByDictionary = {
            ..._articlesByDictionary,
            entry.mdxPath: articles,
          };
        });
        final selectedPath = _selectedMdxPath;
        if (articles.isNotEmpty && selectedPath != null) {
          _preloadNextDictionaryReader(selectedPath);
        }
      }
      return MapEntry(entry.mdxPath, articles);
    }

    final uncachedEntries = dictionaries
        .where((entry) => !cachedResults.containsKey(entry.mdxPath))
        .toList(growable: false);
    final preferredEntry = uncachedEntries
        .where((entry) => entry.mdxPath == preferred)
        .firstOrNull;
    if (preferredEntry != null) {
      await resolveEntry(preferredEntry);
      if (!mounted || request != _lookupRequest) {
        return;
      }
    }
    debugPrint(
      'LumaLex preferred result ready: query=$query '
      'dictionary=$preferred articles=${resolvedResults[preferred]?.length ?? 0} '
      'source=${preferredEntry == null ? 'memory' : 'mdx'} '
      'readyMs=${lookupTimer.elapsedMilliseconds}',
    );
    // The selected dictionary resolves first. Limit the remaining work to a
    // small pool: opening and decompressing every MDX at once can saturate a
    // phone's flash storage, delaying the WebView's first paint and making
    // scrolling feel uneven. Results still publish independently as each
    // dictionary finishes.
    await _resolveBackgroundEntries(
      uncachedEntries
          .where((entry) => entry.mdxPath != preferred)
          .toList(growable: false),
      resolveEntry,
    );
    if (!mounted || request != _lookupRequest) {
      return;
    }
    var completed = resolvedResults;
    final hasExactResult =
        completed.values.any((articles) => articles.isNotEmpty);
    if (!hasExactResult) {
      final fallback = await _findFallbackLookup(query, dictionaries, request);
      if (!mounted || request != _lookupRequest) {
        return;
      }
      if (fallback != null) {
        completed = fallback.results;
        _queryController.value = TextEditingValue(
          text: fallback.query,
          selection: TextSelection.collapsed(offset: fallback.query.length),
        );
        unawaited(
            _wordRecordsReady.then((_) => _recordHistory(fallback.query)));
        _lookupCorrection = (original: query, replacement: fallback.query);
      }
    }
    var selection = preferred;
    if (completed[preferred]?.isEmpty ?? true) {
      selection = dictionaries
              .where((entry) => completed[entry.mdxPath]?.isNotEmpty ?? false)
              .map((entry) => entry.mdxPath)
              .firstOrNull ??
          preferred;
    }
    setState(() {
      _articlesByDictionary = {
        ..._articlesByDictionary,
        ...completed,
      };
      _selectedMdxPath = selection;
      _readerQuery = _queryController.text.trim();
      _retainedReaderPaths = _adoptRetainedReaderPaths(
        _retainReaderPath(
          _retainedReaderPaths,
          selection,
        ),
      );
      _articleAnchor = selection == preferred ? initialAnchor : null;
      _articleScrollOffset =
          selection == preferred ? initialScrollOffset : null;
      _isSearching = false;
    });
    if (_lookupCorrection case final correction?) {
      _scheduleLookupCorrectionDismissal(request, correction);
    }
    _scheduleIndexMigration(
      _libraryEntries,
      delay: const Duration(seconds: 3),
    );
    _scheduleDictionaryWarmup(
      _libraryEntries,
      delay: const Duration(seconds: 4),
    );
    debugPrint(
      'LumaLex query timing: query=$query dictionaries=${dictionaries.length} '
      'withResults=${completed.values.where((value) => value.isNotEmpty).length} '
      'fallback=${_lookupCorrection != null} '
      'totalMs=${lookupTimer.elapsedMilliseconds}',
    );
  }

  void _scheduleLookupCorrectionDismissal(
    int request,
    ({String original, String replacement}) correction,
  ) {
    _lookupCorrectionTimer?.cancel();
    _lookupCorrectionTimer = Timer(lookupCorrectionDisplayDuration, () {
      if (!mounted ||
          request != _lookupRequest ||
          _lookupCorrection != correction) {
        return;
      }
      setState(() => _lookupCorrection = null);
      _lookupCorrectionTimer = null;
    });
  }

  Future<({String query, Map<String, List<Article>> results})?>
      _findFallbackLookup(
    String query,
    List<DictionaryLibraryEntry> dictionaries,
    int request,
  ) async {
    final directCandidates = morphologicalFallbacks(query);
    for (final candidate in directCandidates) {
      final results = await _lookupAlternative(candidate, dictionaries);
      if (!mounted || request != _lookupRequest) return null;
      if (results.values.any((articles) => articles.isNotEmpty)) {
        return (query: candidate, results: results);
      }
    }

    final suggestionPool = <String>[];
    for (final prefix in spellingSearchPrefixes(query)) {
      final batches = await _suggestFromDictionaries(
        prefix,
        dictionaries,
        limit: 20,
      );
      if (!mounted || request != _lookupRequest) return null;
      suggestionPool.addAll(batches);
    }
    for (final candidate in rankSpellingCandidates(query, suggestionPool)) {
      final results = await _lookupAlternative(candidate, dictionaries);
      if (!mounted || request != _lookupRequest) return null;
      if (results.values.any((articles) => articles.isNotEmpty)) {
        return (query: candidate, results: results);
      }
    }
    return null;
  }

  Future<Map<String, List<Article>>> _lookupAlternative(
    String query,
    List<DictionaryLibraryEntry> dictionaries,
  ) async {
    // This path only runs after an exact lookup missed, but it still must not
    // turn a spelling fallback into a burst of simultaneous MDX opens. The
    // same small pool used for normal background results keeps flash I/O and
    // decompression from starving the visible dictionary.
    final results = <String, List<Article>>{};
    await _resolveBackgroundEntries(dictionaries, (entry) async {
      try {
        final articles = await _resolveArticles(entry, query);
        results[entry.mdxPath] = articles;
        return MapEntry(entry.mdxPath, articles);
      } catch (_) {
        const articles = <Article>[];
        results[entry.mdxPath] = articles;
        return MapEntry(entry.mdxPath, articles);
      }
    });
    return results;
  }

  Future<void> _resolveBackgroundEntries(
    List<DictionaryLibraryEntry> entries,
    Future<MapEntry<String, List<Article>>> Function(DictionaryLibraryEntry)
        resolve,
  ) async {
    // Desktop SSDs and the Rust reader cache can comfortably resolve several
    // independent MDX files in parallel. Phones retain the smaller pool to
    // avoid saturating flash and starving the visible WebView.
    final maximumConcurrentLookups = isLumaLexDesktop ? 6 : 2;
    var next = 0;
    Future<void> worker() async {
      while (next < entries.length) {
        final entry = entries[next++];
        await resolve(entry);
      }
    }

    await Future.wait(
      List.generate(
        entries.length.clamp(0, maximumConcurrentLookups),
        (_) => worker(),
      ),
    );
  }

  Future<List<Article>> _resolveArticles(
    DictionaryLibraryEntry entry,
    String query,
  ) async {
    final totalTimer = Stopwatch()..start();
    final memory = _lookupResultCache.get(entry.mdxPath, query);
    if (memory != null) {
      debugPrint(
        'LumaLex lookup timing: dictionary=${entry.title} query=$query '
        'source=memory totalMs=${totalTimer.elapsedMilliseconds}',
      );
      return memory;
    }

    // A raw-exact indexed MDX read takes about 0–2 ms on the representative
    // corpus, while reading and JSON-decoding a 300–400 KB persisted article
    // is measurably slower. Keep the process LRU, but let the source-bound key
    // index remain the only disk cache on this latency-critical path.
    final engineTimer = Stopwatch()..start();
    final articles = await widget.engine.lookup(
      query,
      mdxPath: entry.mdxPath,
    );
    engineTimer.stop();
    _lookupResultCache.put(entry.mdxPath, query, articles);
    debugPrint(
      'LumaLex lookup timing: dictionary=${entry.title} query=$query '
      'source=mdx engineMs=${engineTimer.elapsedMilliseconds} '
      'totalMs=${totalTimer.elapsedMilliseconds}',
    );
    return articles;
  }

  Future<void> _startNewLookup(String query) async {
    // Submitting a query switches the task from editing to reading. Clearing
    // focus here hides the IME and prevents a blinking caret from remaining
    // beside the resolved word while the article is on screen.
    _searchFocusNode.unfocus();
    setState(() {
      _lookupNavigation.clear();
      _suggestionRequest++;
      _suggestions = const [];
      _selectedSuggestionIndex = -1;
    });
    await _lookup(query, preferredMdxPath: _selectedMdxPath);
  }

  Future<LookupLocation?> _captureLookupLocation() async {
    final query = _queryController.text.trim();
    final mdxPath = _selectedMdxPath;
    if (query.isEmpty || mdxPath == null) {
      return null;
    }
    final aggregateOffset = _readerPlatformPolicy.aggregateDictionaryResults
        ? await _aggregateArticleController.readScrollOffset()
        : null;
    final scrollOffset = aggregateOffset ??
        await _articleControllers[mdxPath]?.readScrollOffset() ??
        0;
    return LookupLocation(
      query: query,
      mdxPath: mdxPath,
      scrollOffset: scrollOffset,
    );
  }

  Future<void> _openLinkedHeadword(
    DictionaryLibraryEntry sourceDictionary,
    String headword,
    String? anchor,
    double sourceScrollOffset,
  ) async {
    final sourceQuery = _queryController.text.trim();
    if (sourceQuery.isNotEmpty) {
      setState(() {
        _lookupNavigation.recordDeparture(
          LookupLocation(
            query: sourceQuery,
            mdxPath: sourceDictionary.mdxPath,
            scrollOffset: sourceScrollOffset,
          ),
        );
      });
    }
    _queryController.value = TextEditingValue(
      text: headword,
      selection: TextSelection.collapsed(offset: headword.length),
    );
    await _lookup(
      headword,
      preferredMdxPath: sourceDictionary.mdxPath,
      initialAnchor: anchor,
    );
  }

  Future<void> _goBack() => _moveThroughLookupHistory(forward: false);

  Future<void> _goForward() => _moveThroughLookupHistory(forward: true);

  Future<void> _moveThroughLookupHistory({required bool forward}) async {
    if (_isSearching) {
      return;
    }
    final current = await _captureLookupLocation();
    if (!mounted || current == null) {
      return;
    }
    LookupLocation? destination;
    setState(() {
      destination = forward
          ? _lookupNavigation.goForwardFrom(current)
          : _lookupNavigation.goBackFrom(current);
    });
    final target = destination;
    if (target == null) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    _queryController.value = TextEditingValue(
      text: target.query,
      selection: TextSelection.collapsed(offset: target.query.length),
    );
    await _lookup(
      target.query,
      preferredMdxPath: target.mdxPath,
      initialScrollOffset: target.scrollOffset,
    );
  }

  void _suggest(String rawPrefix) {
    _suggestionDebounce?.cancel();
    final prefix = rawPrefix.trim();
    final request = ++_suggestionRequest;
    final dictionaries = _availableEntries;
    if (prefix.isEmpty || dictionaries.isEmpty) {
      if (mounted) {
        setState(() {
          _suggestions = const [];
          _selectedSuggestionIndex = -1;
        });
      }
      return;
    }

    _suggestionDebounce = Timer(
      const Duration(milliseconds: 180),
      () => _runSuggestion(prefix, request, dictionaries),
    );
  }

  Future<void> _runSuggestion(
    String prefix,
    int request,
    List<DictionaryLibraryEntry> dictionaries,
  ) async {
    try {
      final suggestions = await _suggestFromDictionaries(
        prefix,
        dictionaries,
        limit: 8,
      );
      if (mounted && request == _suggestionRequest) {
        setState(() {
          _suggestions = suggestions;
          _selectedSuggestionIndex = suggestions.isEmpty ? -1 : 0;
        });
      }
    } catch (_) {
      if (mounted && request == _suggestionRequest) {
        setState(() {
          _suggestions = const [];
          _selectedSuggestionIndex = -1;
        });
      }
    }
  }

  Future<List<String>> _suggestFromDictionaries(
    String prefix,
    List<DictionaryLibraryEntry> dictionaries, {
    required int limit,
  }) async {
    final selectedPath = _selectedMdxPath;
    final ordered = List<DictionaryLibraryEntry>.of(dictionaries)
      ..sort((left, right) {
        final leftIsSelected = left.mdxPath == selectedPath;
        final rightIsSelected = right.mdxPath == selectedPath;
        if (leftIsSelected == rightIsSelected) return 0;
        return leftIsSelected ? -1 : 1;
      });
    final seen = <String>{};
    final suggestions = <String>[];
    for (final entry in ordered) {
      final batch = await widget.engine
          .suggest(prefix, limit: limit, mdxPath: entry.mdxPath)
          .catchError((Object _) => const <String>[]);
      for (final suggestion in batch) {
        if (seen.add(suggestion.toLowerCase())) {
          suggestions.add(suggestion);
        }
        if (suggestions.length == limit) {
          return suggestions;
        }
      }
    }
    return suggestions;
  }

  Future<void> _scanIosDictionaryHomeAfterStartup(
    Future<void> libraryReady,
  ) async {
    try {
      await libraryReady;
      await _iosDictionaryHomeReady;
    } catch (error, stackTrace) {
      debugPrint(
        'Unable to prepare the iOS dictionary home: $error\n$stackTrace',
      );
      return;
    }
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_scanIosDictionaryHome());
      }
    });
  }

  Future<void> _pickAndImport() async {
    if (Platform.isIOS) {
      await _scanIosDictionaryHome(announceWhenUnchanged: true);
      return;
    }
    await _pickExternalAndImport();
  }

  Future<void> _pickExternalAndImport() async {
    final target = await _selectDictionaryTarget();
    if (target == null) {
      return;
    }
    await _importDictionaryTarget(target);
  }

  Future<void> _scanIosDictionaryHome({
    bool announceWhenUnchanged = false,
  }) async {
    if (!Platform.isIOS ||
        _isImporting ||
        _isLibraryLoading ||
        _isScanningIosDictionaryHome) {
      return;
    }
    _isScanningIosDictionaryHome = true;
    try {
      final target = await _selectDictionaryTarget(
        useIosDictionaryHome: true,
        showEmptyMessage: announceWhenUnchanged,
      );
      if (target == null || !mounted) {
        return;
      }

      final discoveredPaths = target.mdxPaths.toSet();
      final knownPaths = _libraryEntries.map((entry) => entry.mdxPath).toSet();
      final changedPaths = <String>{};
      for (final entry in _libraryEntries.where(
        (entry) =>
            entry.accessPath == target.accessPath &&
            discoveredPaths.contains(entry.mdxPath),
      )) {
        try {
          final currentVersion =
              await _fileAccess.sourceVersionForMdx(entry.mdxPath);
          if (currentVersion != null && currentVersion != entry.sourceVersion) {
            changedPaths.add(entry.mdxPath);
          }
        } on FileSystemException {
          // The import pass will report a durable read failure. A transient
          // metadata failure must not make a healthy dictionary disappear.
        }
      }
      final missingPaths = _libraryEntries
          .where((entry) => entry.accessPath == target.accessPath)
          .map((entry) => entry.mdxPath)
          .where((path) => !discoveredPaths.contains(path))
          .toSet();
      final pathsToImport = target.mdxPaths
          .where(
            (path) =>
                !knownPaths.contains(path) ||
                _failedMdxPaths.contains(path) ||
                changedPaths.contains(path),
          )
          .toList(growable: false);

      if (missingPaths.isNotEmpty) {
        setState(() {
          _availableMdxPaths = {..._availableMdxPaths}..removeAll(missingPaths);
          _failedMdxPaths.addAll(missingPaths);
        });
      }
      if (pathsToImport.isEmpty) {
        if (announceWhenUnchanged) {
          _showMessage(
            missingPaths.isEmpty
                ? '词典目录已是最新，没有发现新的 MDX 文件。'
                : '已刷新词典目录；有 ${missingPaths.length} 本词典的源文件已移除。',
          );
        }
        return;
      }

      await _importDictionaryTarget((
        mdxPaths: pathsToImport,
        accessPath: target.accessPath,
        copiedIntoIosHome: target.copiedIntoIosHome,
        skippedFolderCount: target.skippedFolderCount,
        mddPathsByMdx: target.mddPathsByMdx,
        sidecarResourcesByMdx: target.sidecarResourcesByMdx,
        androidSourcesByMdx: target.androidSourcesByMdx,
      ));
    } finally {
      _isScanningIosDictionaryHome = false;
    }
  }

  Future<void> _importDictionaryTarget(_DictionaryImportTarget target) async {
    if (!mounted) {
      return;
    }

    final accessPath = target.accessPath;
    final mdxPaths = target.mdxPaths;
    final successfulPaths = <String>[];
    final failedPaths = <String>[];
    final importFailures = <String>[];
    var addedCount = 0;
    var refreshedCount = 0;
    var duplicateCount = 0;
    var unchangedCount = 0;
    var removedRedundantIosCopy = false;
    var libraryChanged = false;
    final changedSourcePaths = <String>{};
    var libraryEntries = List<DictionaryLibraryEntry>.of(_libraryEntries);
    var savedReadGrant = true;
    final progress = ValueNotifier((
      completed: 0,
      total: mdxPaths.length,
      fileName: '正在准备…',
    ));

    setState(() => _isImporting = true);
    final progressDialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          icon: const Icon(Icons.library_add_rounded),
          title: Text('正在检查 ${mdxPaths.length} 本词典'),
          content: ValueListenableBuilder(
            valueListenable: progress,
            builder: (context, value, _) => SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value:
                        value.total == 0 ? null : value.completed / value.total,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '${value.completed}/${value.total}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      try {
        await _fileAccess.retain(accessPath);
      } catch (_) {
        savedReadGrant = false;
      }

      // Refresh existing rows without re-importing or replacing their user
      // settings. Unchanged registrations are deliberately a no-op in the
      // file-access layer, so live readers keep their resource handles.
      for (var index = 0; index < mdxPaths.length; index++) {
        final mdxPath = mdxPaths[index];
        final existingIndex = libraryEntries.indexWhere(
          (entry) => entry.mdxPath == mdxPath,
        );
        if (existingIndex < 0) continue;
        final existing = libraryEntries[existingIndex];
        final source = target.androidSourcesByMdx[mdxPath];
        final mddPaths = target.mddPathsByMdx[mdxPath] ?? existing.mddPaths;
        final sidecars =
            target.sidecarResourcesByMdx[mdxPath] ?? existing.sidecarResources;
        if (source != null) {
          _fileAccess.registerSource(
            mdxPath,
            mddPaths,
            sidecarResources: sidecars,
            accessPath: accessPath,
          );
        }
        progress.value = (
          completed: index,
          total: mdxPaths.length,
          fileName: _dictionaryFileName(mdxPath),
        );
        try {
          final currentSourceVersion = source?.sourceVersion ??
              await _fileAccess.sourceVersionForMdx(mdxPath);
          var refreshed = existing.copyWith(
            accessPath: accessPath,
            sourceRelativePath:
                source?.relativePath ?? existing.sourceRelativePath,
            sourceVersion: currentSourceVersion ?? existing.sourceVersion,
            mddPaths: mddPaths,
            sidecarResources: sidecars,
          );
          final sourceChanged = !_sameDictionarySource(existing, refreshed);
          final sourceVersionChanged = currentSourceVersion != null &&
              currentSourceVersion != existing.sourceVersion;
          if (sourceVersionChanged) {
            _fileAccess.invalidateMdxSource(mdxPath);
            changedSourcePaths.add(mdxPath);
          }
          final mustValidate = _failedMdxPaths.contains(mdxPath) ||
              !_availableMdxPaths.contains(mdxPath) ||
              sourceChanged;
          if (mustValidate) {
            await widget.engine.importMdx(mdxPath: mdxPath);
          }
          if (refreshed.contentFingerprint == null || sourceVersionChanged) {
            refreshed = refreshed.copyWith(
              contentFingerprint: await _fileAccess.fingerprintMdx(mdxPath),
            );
          }
          _failedMdxPaths.remove(mdxPath);
          libraryEntries[existingIndex] = refreshed;
          if (!_sameDictionaryEntry(existing, refreshed)) {
            libraryChanged = true;
            refreshedCount++;
          } else {
            unchangedCount++;
          }
          if (mustValidate) successfulPaths.add(mdxPath);
        } catch (error, stackTrace) {
          debugPrint(
            'Dictionary refresh failed for $mdxPath: $error\n$stackTrace',
          );
          failedPaths.add(mdxPath);
          _failedMdxPaths.add(mdxPath);
          importFailures.add(
            '${_dictionaryFileName(mdxPath)}：${_describeImportError(error)}',
          );
        }
      }

      final hasNewPaths = mdxPaths.any(
        (path) => !libraryEntries.any((entry) => entry.mdxPath == path),
      );
      if (hasNewPaths) {
        // This one-time migration gives legacy rows exact content identities.
        // Hashing is streamed from disk and never holds the MDX in memory.
        for (var index = 0; index < libraryEntries.length; index++) {
          final entry = libraryEntries[index];
          if (entry.contentFingerprint != null) continue;
          progress.value = (
            completed: 0,
            total: mdxPaths.length,
            fileName: '正在校验已有词典：${entry.title}',
          );
          try {
            _fileAccess.registerSource(
              entry.mdxPath,
              entry.mddPaths,
              sidecarResources: entry.sidecarResources,
              accessPath: entry.accessPath,
            );
            if (!await _fileAccess.restore(entry.accessPath)) continue;
            libraryEntries[index] = entry.copyWith(
              contentFingerprint:
                  await _fileAccess.fingerprintMdx(entry.mdxPath),
            );
            libraryChanged = true;
          } catch (error, stackTrace) {
            debugPrint(
              'Unable to fingerprint existing dictionary ${entry.mdxPath}: '
              '$error\n$stackTrace',
            );
          }
        }
      }

      final fingerprints = <String, DictionaryLibraryEntry>{
        for (final entry in libraryEntries)
          if (entry.contentFingerprint case final fingerprint?)
            fingerprint: entry,
      };
      for (var index = 0; index < mdxPaths.length; index++) {
        final mdxPath = mdxPaths[index];
        if (libraryEntries.any((entry) => entry.mdxPath == mdxPath)) {
          progress.value = (
            completed: index + 1,
            total: mdxPaths.length,
            fileName: _dictionaryFileName(mdxPath),
          );
          continue;
        }
        final source = target.androidSourcesByMdx[mdxPath];
        final mddPaths = target.mddPathsByMdx[mdxPath] ?? const <String>[];
        final sidecars = target.sidecarResourcesByMdx[mdxPath] ??
            const <DictionarySidecarResource>[];
        progress.value = (
          completed: index,
          total: mdxPaths.length,
          fileName: _dictionaryFileName(mdxPath),
        );
        try {
          if (source != null) {
            _fileAccess.registerSource(
              mdxPath,
              mddPaths,
              sidecarResources: sidecars,
              accessPath: accessPath,
            );
          }
          final fingerprint = await _fileAccess.fingerprintMdx(mdxPath);
          if (fingerprints.containsKey(fingerprint)) {
            duplicateCount++;
            _fileAccess.discardDuplicateSource(mdxPath);
            continue;
          }
          final title = await widget.engine.importMdx(mdxPath: mdxPath);
          final sourceVersion = source?.sourceVersion ??
              await _fileAccess.sourceVersionForMdx(mdxPath);
          final entry = DictionaryLibraryEntry(
            title: title,
            mdxPath: mdxPath,
            accessPath: accessPath,
            sourceRelativePath: source?.relativePath,
            sourceVersion: sourceVersion,
            contentFingerprint: fingerprint,
            mddPaths: mddPaths,
            sidecarResources: sidecars,
            importedAtMilliseconds: DateTime.now().millisecondsSinceEpoch,
          );
          libraryEntries.add(entry);
          fingerprints[fingerprint] = entry;
          _failedMdxPaths.remove(mdxPath);
          successfulPaths.add(mdxPath);
          addedCount++;
          libraryChanged = true;
        } catch (error, stackTrace) {
          debugPrint(
            'Dictionary import failed for $mdxPath: $error\n$stackTrace',
          );
          failedPaths.add(mdxPath);
          importFailures.add(
            '${_dictionaryFileName(mdxPath)}：${_describeImportError(error)}',
          );
        } finally {
          progress.value = (
            completed: index + 1,
            total: mdxPaths.length,
            fileName: _dictionaryFileName(mdxPath),
          );
        }
      }

      if (libraryChanged) {
        libraryEntries = List<DictionaryLibraryEntry>.of(
          await widget.library.replaceAll(libraryEntries),
        );
      }

      if (mounted) {
        for (final path in changedSourcePaths) {
          _lookupResultCache.removeDictionary(path);
          _readerPositionCache.removeDictionary(path);
        }
        setState(() {
          _libraryEntries = libraryEntries;
          _availableMdxPaths = {..._availableMdxPaths}
            ..removeAll(failedPaths)
            ..addAll(successfulPaths);
          _articlesByDictionary = {..._articlesByDictionary}
            ..removeWhere((path, _) => changedSourcePaths.contains(path));
          _retainedReaderPaths = _adoptRetainedReaderPaths(
            _retainedReaderPaths
                .where((path) => !changedSourcePaths.contains(path)),
          );
          _selectedMdxPath ??= dictionaryEntriesForScope(
            libraryEntries.where(
              (entry) =>
                  entry.isEnabled && _availableMdxPaths.contains(entry.mdxPath),
            ),
            _activeDictionaryScopeId,
          ).map((entry) => entry.mdxPath).firstOrNull;
        });
      }
      // Reader handles have already been warmed during import. Give the user
      // a quiet window to search before starting disposable full-key indexes;
      // Rust cancels this work if a foreground request arrives later.
      if (successfulPaths.isNotEmpty) {
        _scheduleIndexMigration(
          libraryEntries,
          delay: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _isImporting = false);
      }
      await progressDialog;
      progress.dispose();
    }

    if (target.copiedIntoIosHome &&
        addedCount == 0 &&
        duplicateCount == mdxPaths.length &&
        failedPaths.isEmpty) {
      try {
        removedRedundantIosCopy = await _iosDictionaryHome
            .removeRedundantCopiedImport(target.accessPath);
      } on FileSystemException catch (error) {
        debugPrint('Unable to remove redundant iOS dictionary copy: $error');
      }
    }

    if (!mounted) {
      return;
    }
    final handledCount =
        addedCount + refreshedCount + duplicateCount + unchangedCount;
    if (handledCount == 0) {
      _showMessage(
        '发现 ${mdxPaths.length} 个 MDX 文件，但都无法读取。'
        '${importFailures.isEmpty ? '' : '\n${importFailures.first}'}',
      );
      return;
    }

    final summary = <String>[
      '发现 ${mdxPaths.length} 个 MDX',
      if (target.copiedIntoIosHome && !removedRedundantIosCopy)
        '已复制到 LumaLex/Dictionaries',
      if (removedRedundantIosCopy) '重复副本已清理',
      if (addedCount > 0) '新增 $addedCount 本',
      if (refreshedCount > 0) '刷新 $refreshedCount 本',
      if (duplicateCount > 0) '跳过重复 $duplicateCount 本',
      if (unchangedCount > 0) '保持不变 $unchangedCount 本',
      if (failedPaths.isNotEmpty) '失败 ${failedPaths.length} 本',
      if (target.skippedFolderCount > 0)
        '跳过 ${target.skippedFolderCount} 个无法读取的子目录',
      if (!savedReadGrant) '未能保存重启后的访问授权',
      '快速检索索引正在后台建立',
    ];
    _showMessage(summary.join(' · '));

    final currentQuery = _queryController.text.trim();
    final selectedPath = _selectedMdxPath;
    if (changedSourcePaths.isNotEmpty &&
        currentQuery.isNotEmpty &&
        changedSourcePaths.any(successfulPaths.contains)) {
      await _lookup(
        currentQuery,
        preferredMdxPath: selectedPath,
      );
    }
  }

  String _describeImportError(Object error) {
    final text = error.toString().trim();
    if (text.isEmpty) {
      return '系统没有返回具体原因。';
    }
    return text.length <= 180 ? text : '${text.substring(0, 177)}…';
  }

  bool _sameDictionarySource(
    DictionaryLibraryEntry left,
    DictionaryLibraryEntry right,
  ) =>
      left.mdxPath == right.mdxPath &&
      left.accessPath == right.accessPath &&
      left.sourceRelativePath == right.sourceRelativePath &&
      left.sourceVersion == right.sourceVersion &&
      _sameStrings(left.mddPaths, right.mddPaths) &&
      _sameSidecars(left.sidecarResources, right.sidecarResources);

  bool _sameDictionaryEntry(
    DictionaryLibraryEntry left,
    DictionaryLibraryEntry right,
  ) =>
      left.title == right.title &&
      left.contentFingerprint == right.contentFingerprint &&
      left.importedAtMilliseconds == right.importedAtMilliseconds &&
      left.isEnabled == right.isEnabled &&
      left.groupId == right.groupId &&
      _sameDictionarySource(left, right);

  bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  bool _sameSidecars(
    List<DictionarySidecarResource> left,
    List<DictionarySidecarResource> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].uri != right[index].uri ||
          left[index].relativePath != right[index].relativePath) {
        return false;
      }
    }
    return true;
  }

  Future<void> _ensureIndexesInBackground(
    List<DictionaryLibraryEntry> entries,
  ) async {
    // Missing indexes are migrated sequentially so a large library cannot
    // saturate the machine. An active lookup always wins; migration schedules
    // itself again after the current lookup settles.
    final enabledEntries =
        entries.where((entry) => entry.isEnabled).toList(growable: false)
          ..sort((left, right) {
            final leftIsSelected = left.mdxPath == _selectedMdxPath;
            final rightIsSelected = right.mdxPath == _selectedMdxPath;
            if (leftIsSelected == rightIsSelected) return 0;
            return leftIsSelected ? -1 : 1;
          });
    for (final entry in enabledEntries) {
      if (!mounted) {
        return;
      }
      if (_isSearching || _isImporting) {
        _scheduleIndexMigration(entries);
        return;
      }
      if (!_availableMdxPaths.contains(entry.mdxPath)) {
        continue;
      }
      try {
        await widget.engine.ensureIndex(mdxPath: entry.mdxPath);
      } catch (error) {
        if (error.toString().toLowerCase().contains('cancelled')) {
          _scheduleIndexMigration(
            entries,
            delay: const Duration(seconds: 3),
          );
          return;
        }
        // A failed cache migration must never make a readable dictionary
        // unavailable. A later import can retry it.
      }
    }
  }

  void _scheduleIndexMigration(
    List<DictionaryLibraryEntry> entries, {
    Duration delay = const Duration(seconds: 1),
  }) {
    if (!mounted || entries.isEmpty) {
      return;
    }
    _indexMigrationDelay?.cancel();
    _indexMigrationDelay = Timer(
      delay,
      () {
        _indexMigrationDelay = null;
        unawaited(_ensureIndexesInBackground(entries));
      },
    );
  }

  Future<_DictionaryImportTarget?> _selectDictionaryTarget({
    bool useIosDictionaryHome = false,
    bool showEmptyMessage = true,
  }) async {
    if (isLumaLexDesktop || Platform.isIOS) {
      String? directoryPath;
      var copiedIntoIosHome = false;
      try {
        if (Platform.isIOS) {
          if (useIosDictionaryHome) {
            directoryPath = (await _iosDictionaryHomeReady)?.path;
          } else {
            String? initialDirectoryPath;
            try {
              initialDirectoryPath = (await _iosDictionaryHomeReady)?.path;
            } on FileSystemException {
              // A full or unavailable app container must not prevent the user
              // from authorizing an existing dictionary folder elsewhere.
            }
            final selection = await _fileAccess.pickIosDictionaryFolder(
              initialDirectoryPath: initialDirectoryPath,
            );
            directoryPath = selection?.path;
            copiedIntoIosHome = selection?.wasCopiedIntoDictionaryHome == true;
          }
        } else {
          directoryPath = await FilePicker.getDirectoryPath(
            dialogTitle: '选择词典总文件夹（将扫描所有子文件夹）',
          );
        }
      } on PlatformException catch (error) {
        debugPrint(
          'Dictionary folder picker failed: ${error.code}; '
          '${error.message}; details=${error.details}',
        );
        if (mounted) {
          _showMessage(error.message ?? '无法打开系统文件夹选择器。');
        }
        return null;
      } on FormatException catch (error) {
        debugPrint('Dictionary folder picker returned invalid data: $error');
        if (mounted) {
          _showMessage('系统返回的文件夹信息无效，请重试。');
        }
        return null;
      } on FileSystemException {
        if (mounted && showEmptyMessage) {
          _showMessage('无法建立 LumaLex 词典目录，请检查设备存储空间。');
        }
        return null;
      }
      if (directoryPath == null) {
        return null;
      }

      try {
        final scan = await scanDictionaryFolder(directoryPath);
        if (scan.mdxPaths.isEmpty) {
          if (mounted && showEmptyMessage) {
            _showMessage(
              useIosDictionaryHome
                  ? '还没有找到 MDX。请先将词典文件夹放入“${IosDictionaryHome.displayPath}”。'
                  : '所选文件夹及其子文件夹中没有 MDX 文件。',
            );
          }
          return null;
        }
        return (
          mdxPaths: scan.mdxPaths,
          accessPath: directoryPath,
          copiedIntoIosHome: copiedIntoIosHome,
          skippedFolderCount: scan.unreadableDirectoryCount,
          mddPathsByMdx: const <String, List<String>>{},
          sidecarResourcesByMdx: const <String,
              List<DictionarySidecarResource>>{},
          androidSourcesByMdx: const <String, AndroidDictionarySource>{},
        );
      } on FileSystemException {
        if (mounted) {
          _showMessage('无法读取所选文件夹。请检查访问权限后重试。');
        }
        return null;
      }
    }

    if (Platform.isAndroid) {
      try {
        final selection = await _fileAccess.pickAndroidDictionaryFolder();
        if (selection == null) {
          return null;
        }
        if (selection.dictionaries.isEmpty) {
          if (mounted) {
            _showMessage('所选文件夹及其子文件夹中没有 MDX 文件。');
          }
          return null;
        }
        final mddPathsByMdx = <String, List<String>>{
          for (final source in selection.dictionaries)
            source.mdxPath: source.mddPaths,
        };
        final sidecarResourcesByMdx = <String, List<DictionarySidecarResource>>{
          for (final source in selection.dictionaries)
            source.mdxPath: source.sidecarResources,
        };
        final androidSourcesByMdx = <String, AndroidDictionarySource>{
          for (final source in selection.dictionaries) source.mdxPath: source,
        };
        return (
          mdxPaths:
              selection.dictionaries.map((source) => source.mdxPath).toList(
                    growable: false,
                  ),
          accessPath: selection.accessPath,
          copiedIntoIosHome: false,
          skippedFolderCount: 0,
          mddPathsByMdx: mddPathsByMdx,
          sidecarResourcesByMdx: sidecarResourcesByMdx,
          androidSourcesByMdx: androidSourcesByMdx,
        );
      } on PlatformException catch (error) {
        if (mounted) {
          _showMessage(error.message ?? '无法读取所选文件夹。请检查访问权限后重试。');
        }
        return null;
      } on FormatException {
        if (mounted) {
          _showMessage('所选文件夹返回的数据无效，请重试。');
        }
        return null;
      }
    }

    final picked = await FilePicker.pickFile(
      dialogTitle: '选择 MDX 词典文件',
      type: FileType.custom,
      allowedExtensions: const ['mdx'],
    );
    final mdxPath = picked?.path;
    if (mdxPath == null) {
      return null;
    }
    return (
      mdxPaths: <String>[mdxPath],
      accessPath: mdxPath,
      copiedIntoIosHome: false,
      skippedFolderCount: 0,
      mddPathsByMdx: const <String, List<String>>{},
      sidecarResourcesByMdx: const <String, List<DictionarySidecarResource>>{},
      androidSourcesByMdx: const <String, AndroidDictionarySource>{},
    );
  }

  String _dictionaryFileName(String path) {
    final segments = File(path).uri.pathSegments;
    return segments.isEmpty ? path : segments.last;
  }

  Future<void> _loadWordRecords({int? expectedMutationGeneration}) async {
    try {
      final historyRequest = widget.wordRecords.loadHistory();
      final favoritesRequest = widget.wordRecords.loadFavorites();
      final reviewCardsRequest = widget.wordRecords.loadReviewCards();
      final textScaleRequest = widget.wordRecords.loadTextScale();
      final history = await historyRequest;
      final favorites = await favoritesRequest;
      final storedReviewCards = await reviewCardsRequest;
      final textScale = await textScaleRequest;
      final synchronizedReviewCards = synchronizeReviewCards(
        favorites,
        storedReviewCards,
        now: DateTime.now(),
      );
      if (expectedMutationGeneration != null &&
          expectedMutationGeneration != _wordRecordsMutationGeneration) {
        return;
      }
      if (mounted) {
        setState(() {
          _history = history.take(200).toList(growable: false);
          _favorites = favorites;
          _reviewCards = synchronizedReviewCards;
          _textScale = textScale;
        });
      }
      if (!_sameReviewCards(storedReviewCards, synchronizedReviewCards)) {
        unawaited(widget.wordRecords.saveReviewCards(synchronizedReviewCards));
      }
    } catch (_) {
      if (mounted) {
        _showMessage('无法读取查词历史和收藏。');
      }
    }
  }

  Future<void> _refreshWordRecords() async {
    await _wordRecordsReady;
    if (!mounted) return;
    final expectedMutationGeneration = _wordRecordsMutationGeneration;
    await _loadWordRecords(
      expectedMutationGeneration: expectedMutationGeneration,
    );
  }

  Future<void> _recordHistory(String word) async {
    final normalized = word.trim();
    if (normalized.isEmpty) {
      return;
    }
    final updated = addRecentWord(_history, normalized);
    _wordRecordsMutationGeneration++;
    if (mounted) {
      setState(() => _history = updated);
    }
    try {
      await widget.wordRecords.saveHistory(updated);
    } catch (_) {
      if (mounted) {
        _showMessage('查词成功，但无法保存历史记录。');
      }
    }
  }

  bool _isFavorite(String word) => _favorites.any(
        (favorite) => favorite.toLowerCase() == word.trim().toLowerCase(),
      );

  bool _sameReviewCards(
    List<ReviewCard> left,
    List<ReviewCard> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index].toJson().toString() != right[index].toJson().toString()) {
        return false;
      }
    }
    return true;
  }

  List<ReviewCard> _addGlossToNewReviewCard(
    List<ReviewCard> cards,
    String word, {
    String? articleHtml,
  }) {
    final selectedPath = _selectedMdxPath;
    final mainArticle = selectedPath == null
        ? null
        : _articlesByDictionary[selectedPath]?.firstOrNull;
    final gloss = reviewGlossFromHtml(articleHtml ?? mainArticle?.html ?? '');
    if (gloss == null) {
      return cards;
    }
    final normalized = word.trim().toLowerCase();
    return cards
        .map(
          (card) => card.word.toLowerCase() == normalized
              ? card.copyWith(gloss: gloss)
              : card,
        )
        .toList(growable: false);
  }

  Future<void> _toggleFavorite(
    String word, {
    String? articleHtml,
  }) async {
    final normalized = word.trim();
    if (normalized.isEmpty) {
      return;
    }
    final updated = toggleSavedWord(_favorites, normalized);
    final wasFavorite = _isFavorite(normalized);
    final synchronizedReviewCards = synchronizeReviewCards(
      updated,
      _reviewCards,
      now: DateTime.now(),
    );
    final reviewCards = !wasFavorite
        ? _addGlossToNewReviewCard(
            synchronizedReviewCards,
            normalized,
            articleHtml: articleHtml,
          )
        : synchronizedReviewCards;
    _wordRecordsMutationGeneration++;
    if (mounted) {
      setState(() {
        _favorites = updated;
        _reviewCards = reviewCards;
      });
    }
    try {
      await Future.wait([
        widget.wordRecords.saveFavorites(updated),
        widget.wordRecords.saveReviewCards(reviewCards),
      ]);
    } catch (_) {
      if (mounted) {
        _showMessage('无法保存收藏。');
      }
    }
  }

  Future<void> _removeHistoryWords(Iterable<String> words) async {
    final updated = removeSavedWords(_history, words);
    _wordRecordsMutationGeneration++;
    if (mounted) {
      setState(() => _history = updated);
    }
    try {
      await widget.wordRecords.saveHistory(updated);
    } catch (_) {
      if (mounted) {
        _showMessage('无法保存历史记录的删除结果。');
      }
    }
  }

  Future<void> _removeFavoriteWords(Iterable<String> words) async {
    final updated = removeSavedWords(_favorites, words);
    final reviewCards = synchronizeReviewCards(
      updated,
      _reviewCards,
      now: DateTime.now(),
    );
    _wordRecordsMutationGeneration++;
    if (mounted) {
      setState(() {
        _favorites = updated;
        _reviewCards = reviewCards;
      });
    }
    try {
      await Future.wait([
        widget.wordRecords.saveFavorites(updated),
        widget.wordRecords.saveReviewCards(reviewCards),
      ]);
    } catch (_) {
      if (mounted) {
        _showMessage('无法保存收藏的删除结果。');
      }
    }
  }

  Future<void> _openRecordedWord(String word) async {
    Navigator.of(context).pop();
    _queryController.value = TextEditingValue(
      text: word,
      selection: TextSelection.collapsed(offset: word.length),
    );
    await _startNewLookup(word);
  }

  Future<void> _showWordRecords() async {
    var managingHistory = false;
    var managingFavorites = false;
    final selectedHistory = <String>{};
    final selectedFavorites = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => DefaultTabController(
          length: 2,
          child: SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(icon: Icon(Icons.history), text: '历史'),
                      Tab(icon: Icon(Icons.star_outline), text: '收藏'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildWordRecordsTab(
                          words: _history,
                          emptyMessage: '还没有查词历史。',
                          managing: managingHistory,
                          selectedWords: selectedHistory,
                          onToggleManaging: () {
                            setSheetState(() {
                              managingHistory = !managingHistory;
                              selectedHistory.clear();
                            });
                          },
                          onToggleSelected: (word) {
                            setSheetState(() {
                              if (!selectedHistory.add(word)) {
                                selectedHistory.remove(word);
                              }
                            });
                          },
                          onToggleSelectAll: () {
                            setSheetState(() {
                              if (selectedHistory.length == _history.length) {
                                selectedHistory.clear();
                              } else {
                                selectedHistory
                                  ..clear()
                                  ..addAll(_history);
                              }
                            });
                          },
                          onDeleteSelected: () async {
                            await _removeHistoryWords(selectedHistory);
                            if (context.mounted) {
                              setSheetState(() {
                                selectedHistory.clear();
                                if (_history.isEmpty) managingHistory = false;
                              });
                            }
                          },
                          onClearAll: () async {
                            if (!await _confirmClearWordList(
                              context,
                              title: '清空查词历史？',
                              message: '全部历史记录将被删除，此操作无法撤销。',
                            )) {
                              return;
                            }
                            await _removeHistoryWords(_history);
                            if (context.mounted) {
                              setSheetState(() {
                                selectedHistory.clear();
                                managingHistory = false;
                              });
                            }
                          },
                          trailingBuilder: (word) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: _isFavorite(word) ? '取消收藏' : '收藏',
                                icon: Icon(
                                  _isFavorite(word)
                                      ? Icons.star
                                      : Icons.star_outline,
                                ),
                                onPressed: () async {
                                  await _toggleFavorite(word);
                                  if (context.mounted) setSheetState(() {});
                                },
                              ),
                              IconButton(
                                tooltip: '删除这条历史',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  await _removeHistoryWords([word]);
                                  if (context.mounted) setSheetState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                        _buildWordRecordsTab(
                          words: _favorites,
                          emptyMessage: '还没有收藏单词。',
                          managing: managingFavorites,
                          selectedWords: selectedFavorites,
                          onToggleManaging: () {
                            setSheetState(() {
                              managingFavorites = !managingFavorites;
                              selectedFavorites.clear();
                            });
                          },
                          onToggleSelected: (word) {
                            setSheetState(() {
                              if (!selectedFavorites.add(word)) {
                                selectedFavorites.remove(word);
                              }
                            });
                          },
                          onToggleSelectAll: () {
                            setSheetState(() {
                              if (selectedFavorites.length ==
                                  _favorites.length) {
                                selectedFavorites.clear();
                              } else {
                                selectedFavorites
                                  ..clear()
                                  ..addAll(_favorites);
                              }
                            });
                          },
                          onDeleteSelected: () async {
                            await _removeFavoriteWords(selectedFavorites);
                            if (context.mounted) {
                              setSheetState(() {
                                selectedFavorites.clear();
                                if (_favorites.isEmpty) {
                                  managingFavorites = false;
                                }
                              });
                            }
                          },
                          onClearAll: () async {
                            if (!await _confirmClearWordList(
                              context,
                              title: '清空全部收藏？',
                              message: '全部收藏单词将被删除，此操作无法撤销。',
                            )) {
                              return;
                            }
                            await _removeFavoriteWords(_favorites);
                            if (context.mounted) {
                              setSheetState(() {
                                selectedFavorites.clear();
                                managingFavorites = false;
                              });
                            }
                          },
                          trailingBuilder: (word) => IconButton(
                            tooltip: '从收藏中删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await _removeFavoriteWords([word]);
                              if (context.mounted) setSheetState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWordRecordsTab({
    required List<String> words,
    required String emptyMessage,
    required bool managing,
    required Set<String> selectedWords,
    required VoidCallback onToggleManaging,
    required ValueChanged<String> onToggleSelected,
    required VoidCallback onToggleSelectAll,
    required Future<void> Function() onDeleteSelected,
    required Future<void> Function() onClearAll,
    required Widget Function(String word) trailingBuilder,
  }) {
    final allSelected =
        words.isNotEmpty && selectedWords.length == words.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Text(managing
                  ? '已选 ${selectedWords.length} 项'
                  : '共 ${words.length} 项'),
              const Spacer(),
              if (managing) ...[
                TextButton(
                  onPressed: words.isEmpty ? null : onToggleSelectAll,
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                TextButton.icon(
                  onPressed: selectedWords.isEmpty ? null : onDeleteSelected,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
                TextButton(
                    onPressed: onToggleManaging, child: const Text('完成')),
              ] else ...[
                TextButton(
                  onPressed: words.isEmpty ? null : onToggleManaging,
                  child: const Text('管理'),
                ),
                TextButton(
                  onPressed: words.isEmpty ? null : onClearAll,
                  child: const Text('清空'),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: words.isEmpty
              ? Center(child: Text(emptyMessage))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: words.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final word = words[index];
                    final selected = selectedWords.contains(word);
                    return ListTile(
                      leading: managing
                          ? Checkbox(
                              value: selected,
                              onChanged: (_) => onToggleSelected(word),
                            )
                          : const Icon(Icons.search),
                      title: Text(word),
                      selected: managing && selected,
                      trailing: managing ? null : trailingBuilder(word),
                      onTap: managing
                          ? () => onToggleSelected(word)
                          : () => _openRecordedWord(word),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<bool> _confirmClearWordList(
    BuildContext context, {
    required String title,
    required String message,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清空'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _loadLibrary() async {
    try {
      if (_supportsDictionaryGroups) {
        _dictionaryGroupSnapshot = await widget.dictionaryGroups.load();
      }
      var entries = await widget.library.load();
      entries = await _refreshAndroidLibrarySources(entries);
      entries = await _refreshIosLibrarySources(entries);
      if (_supportsDictionaryGroups) {
        final knownGroupIds =
            _dictionaryGroupSnapshot.groups.map((group) => group.id).toSet();
        var repairedUnknownGroup = false;
        final repairedEntries = entries.map((entry) {
          if (entry.groupId == null || knownGroupIds.contains(entry.groupId)) {
            return entry;
          }
          repairedUnknownGroup = true;
          return entry.copyWith(clearGroupId: true);
        }).toList(growable: false);
        if (repairedUnknownGroup) {
          entries = await widget.library.replaceAll(repairedEntries);
        }
      }
      if (mounted) {
        setState(() => _libraryEntries = entries);
      }
      final scopedEnabledEntries = dictionaryEntriesForScope(
        entries.where((entry) => entry.isEnabled),
        _activeDictionaryScopeId,
      );
      final enabledEntries = <DictionaryLibraryEntry>[
        ...scopedEnabledEntries,
        ...entries.where(
          (entry) => entry.isEnabled && !scopedEnabledEntries.contains(entry),
        ),
      ];
      final available = <String>{};
      // Only the first usable dictionary is on the startup critical path.
      // Opening a large library sequentially used to keep the whole lookup UI
      // blocked even though the user needs just one dictionary to start.
      for (final entry in enabledEntries) {
        if (!mounted) {
          return;
        }
        if (await _prepareDictionary(entry)) {
          available.add(entry.mdxPath);
          // The normal app becomes interactive after restoring its first
          // dictionary, then warms the rest in the background. A PROCESS_TEXT
          // window is already committed to one selected word: rendering that
          // first dictionary as 1/1 and later rebuilding it as 1/N produces a
          // conspicuous second page load. Restore its complete enabled set
          // before the one aggregate lookup instead.
          if (!widget.processTextMode) break;
        }
      }
      if (mounted) {
        setState(() {
          _availableMdxPaths = available;
          _selectedMdxPath = scopedEnabledEntries
              .where((entry) => available.contains(entry.mdxPath))
              .map((entry) => entry.mdxPath)
              .firstOrNull;
          _isLibraryLoading = false;
        });
      }
      if (enabledEntries.isNotEmpty && available.isEmpty && mounted) {
        _showMessage('已保留词典库，但原文件授权已失效。请重新导入其中一本词典以恢复访问。');
      }
      if (available.isNotEmpty) {
        _scheduleIndexMigration(entries);
        _scheduleDictionaryWarmup(entries);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('无法读取本地词典库。');
      }
    } finally {
      if (mounted) {
        setState(() => _isLibraryLoading = false);
      }
    }
  }

  Future<List<DictionaryLibraryEntry>> _refreshIosLibrarySources(
    List<DictionaryLibraryEntry> entries, {
    Set<String>? changedPaths,
    Set<String>? unavailablePaths,
  }) async {
    if (!Platform.isIOS || entries.isEmpty) return entries;
    final refreshed = List<DictionaryLibraryEntry>.of(entries);
    final restoredAccessPaths = <String, Future<bool>>{};
    var changed = false;
    for (var index = 0; index < refreshed.length; index++) {
      final entry = refreshed[index];
      final restored = await restoredAccessPaths.putIfAbsent(
        entry.accessPath,
        () async {
          try {
            return await _fileAccess.restore(entry.accessPath);
          } catch (_) {
            return false;
          }
        },
      );
      if (!restored) {
        unavailablePaths?.add(entry.mdxPath);
        continue;
      }
      try {
        final currentVersion =
            await _fileAccess.sourceVersionForMdx(entry.mdxPath);
        if (currentVersion == null || currentVersion == entry.sourceVersion) {
          continue;
        }
        _fileAccess.invalidateMdxSource(entry.mdxPath);
        refreshed[index] = entry.copyWith(
          sourceVersion: currentVersion,
          contentFingerprint: entry.sourceVersion == null
              ? entry.contentFingerprint
              : await _fileAccess.fingerprintMdx(entry.mdxPath),
        );
        changedPaths?.add(entry.mdxPath);
        changed = true;
      } on FileSystemException {
        // Keep the row. The ordinary preparation pass below will mark the
        // source unavailable and lets the user restore or remove it.
        if (!await File(entry.mdxPath).exists()) {
          unavailablePaths?.add(entry.mdxPath);
        }
      }
    }
    if (!changed) return entries;
    return widget.library.replaceAll(refreshed);
  }

  Future<void> _refreshIosSourcesAfterForeground() async {
    if (!Platform.isIOS ||
        _isRefreshingIosSources ||
        _isLibraryLoading ||
        _isImporting) {
      return;
    }
    _isRefreshingIosSources = true;
    try {
      final changedPaths = <String>{};
      final unavailablePaths = <String>{};
      final refreshed = await _refreshIosLibrarySources(
        _libraryEntries,
        changedPaths: changedPaths,
        unavailablePaths: unavailablePaths,
      );
      if (!mounted) return;
      final affectedPaths = {...changedPaths, ...unavailablePaths};
      if (affectedPaths.isNotEmpty) {
        for (final path in affectedPaths) {
          _lookupResultCache.removeDictionary(path);
          _readerPositionCache.removeDictionary(path);
        }
        setState(() {
          _libraryEntries = refreshed;
          _availableMdxPaths = {..._availableMdxPaths}
            ..removeAll(unavailablePaths);
          _failedMdxPaths.addAll(unavailablePaths);
          _articlesByDictionary = {..._articlesByDictionary}
            ..removeWhere((path, _) => affectedPaths.contains(path));
          _retainedReaderPaths = _adoptRetainedReaderPaths(
            _retainedReaderPaths.where(
              (path) => !affectedPaths.contains(path),
            ),
          );
        });
      }

      await _scanIosDictionaryHome();
      if (!mounted || changedPaths.isEmpty) return;
      final currentQuery = _queryController.text.trim();
      if (currentQuery.isNotEmpty && _availableEntries.isNotEmpty) {
        await _lookup(
          currentQuery,
          preferredMdxPath: _selectedMdxPath,
        );
      }
    } finally {
      _isRefreshingIosSources = false;
    }
  }

  Future<List<DictionaryLibraryEntry>> _refreshAndroidLibrarySources(
    List<DictionaryLibraryEntry> entries,
  ) async {
    if (!Platform.isAndroid || entries.isEmpty) return entries;
    final refreshed = List<DictionaryLibraryEntry>.of(entries);
    var changed = false;
    final accessPaths = entries
        .map((entry) => entry.accessPath)
        .where((path) => path.startsWith('content://'))
        .toSet();
    for (final accessPath in accessPaths) {
      try {
        final sources = await _fileAccess.scanAndroidDictionaryFolder(
          accessPath,
          refresh: true,
        );
        final usedPaths = <String>{};
        for (var index = 0; index < refreshed.length; index++) {
          final entry = refreshed[index];
          if (entry.accessPath != accessPath) continue;
          AndroidDictionarySource? source = sources
              .where(
                (candidate) =>
                    candidate.mdxPath == entry.mdxPath &&
                    !usedPaths.contains(candidate.mdxPath),
              )
              .firstOrNull;
          source ??= sources
              .where(
                (candidate) =>
                    entry.sourceRelativePath != null &&
                    candidate.relativePath == entry.sourceRelativePath &&
                    !usedPaths.contains(candidate.mdxPath),
              )
              .firstOrNull;
          if (source == null && entry.sourceRelativePath == null) {
            final fileName = _sourceFileName(entry.mdxPath);
            final matches = sources
                .where(
                  (candidate) =>
                      _sourceFileName(candidate.relativePath) == fileName &&
                      !usedPaths.contains(candidate.mdxPath),
                )
                .toList(growable: false);
            if (matches.length == 1) source = matches.single;
          }
          if (source == null) {
            _fileAccess.discardUnavailableSource(entry.mdxPath);
            continue;
          }
          usedPaths.add(source.mdxPath);
          final sourceVersionChanged = entry.sourceVersion != null &&
              source.sourceVersion != null &&
              entry.sourceVersion != source.sourceVersion;
          final next = entry.copyWith(
            mdxPath: source.mdxPath,
            accessPath: accessPath,
            sourceRelativePath: source.relativePath,
            sourceVersion: source.sourceVersion,
            clearContentFingerprint: sourceVersionChanged,
            mddPaths: source.mddPaths,
            sidecarResources: source.sidecarResources,
          );
          if (!_sameDictionaryEntry(entry, next)) {
            refreshed[index] = next;
            changed = true;
            if (entry.mdxPath != next.mdxPath) {
              _fileAccess.unregisterSource(entry.mdxPath);
            } else if (sourceVersionChanged) {
              _fileAccess.invalidateMdxSource(entry.mdxPath);
            }
          }
        }
      } catch (error, stackTrace) {
        debugPrint(
          'Unable to refresh Android dictionary folder $accessPath: '
          '$error\n$stackTrace',
        );
      }
    }
    if (!changed) return entries;
    return widget.library.replaceAll(refreshed);
  }

  String _sourceFileName(String value) {
    final slashName = value.split('/').last;
    final decoded = Uri.decodeComponent(slashName);
    final nestedSlash = decoded.lastIndexOf('/');
    return (nestedSlash < 0 ? decoded : decoded.substring(nestedSlash + 1))
        .toLowerCase();
  }

  bool get _hasPendingEnabledDictionary => _libraryEntries.any(
        (entry) =>
            entry.isEnabled &&
            _entryMatchesActiveDictionaryScope(entry) &&
            !_availableMdxPaths.contains(entry.mdxPath) &&
            !_failedMdxPaths.contains(entry.mdxPath),
      );

  Future<void> _prepareEnabledDictionariesForAggregateLookup() async {
    final pending = _libraryEntries
        .where(
          (entry) =>
              entry.isEnabled &&
              _entryMatchesActiveDictionaryScope(entry) &&
              !_availableMdxPaths.contains(entry.mdxPath) &&
              !_failedMdxPaths.contains(entry.mdxPath),
        )
        .toList(growable: false);
    if (pending.isEmpty) return;

    final restored = <String>{};
    // Match the existing warmup policy: opening large MDX sources in series
    // avoids a short burst of competing file-provider reads on mobile flash.
    for (final entry in pending) {
      if (!mounted) return;
      if (await _prepareDictionary(entry)) {
        restored.add(entry.mdxPath);
      }
    }
    if (!mounted || restored.isEmpty) return;
    setState(() {
      _availableMdxPaths = {..._availableMdxPaths, ...restored};
      _selectedMdxPath ??= restored.firstOrNull;
    });
  }

  Future<bool> _prepareDictionary(DictionaryLibraryEntry entry) {
    final existing = _dictionaryPreparations[entry.mdxPath];
    if (existing != null) return existing;
    final preparation = _prepareDictionaryOnce(entry);
    _dictionaryPreparations[entry.mdxPath] = preparation;
    unawaited(
      preparation.then<void>((_) {
        if (identical(_dictionaryPreparations[entry.mdxPath], preparation)) {
          _dictionaryPreparations.remove(entry.mdxPath);
        }
      }),
    );
    return preparation;
  }

  Future<bool> _prepareDictionaryOnce(DictionaryLibraryEntry entry) async {
    try {
      _fileAccess.registerSource(
        entry.mdxPath,
        entry.mddPaths,
        sidecarResources: entry.sidecarResources,
        accessPath: entry.accessPath,
      );
      if (!await _fileAccess.restore(entry.accessPath)) {
        throw StateError(
            'No reusable file-access grant exists for this dictionary.');
      }
      await widget.engine.importMdx(mdxPath: entry.mdxPath);
      _failedMdxPaths.remove(entry.mdxPath);
      return true;
    } catch (error, stackTrace) {
      debugPrint(
        'Dictionary source preparation failed for ${entry.mdxPath}: '
        '$error\n$stackTrace',
      );
      _failedMdxPaths.add(entry.mdxPath);
      return false;
    }
  }

  void _scheduleDictionaryWarmup(
    List<DictionaryLibraryEntry> entries, {
    Duration delay = const Duration(seconds: 3),
  }) {
    _dictionaryWarmupDelay?.cancel();
    final generation = ++_dictionaryWarmupGeneration;
    final hasPendingDictionary = entries.any(
      (entry) =>
          entry.isEnabled &&
          !_availableMdxPaths.contains(entry.mdxPath) &&
          !_failedMdxPaths.contains(entry.mdxPath),
    );
    if (!mounted || !hasPendingDictionary) {
      _dictionaryWarmupDelay = null;
      return;
    }
    _dictionaryWarmupDelay = Timer(delay, () {
      _dictionaryWarmupDelay = null;
      unawaited(_warmRemainingDictionaries(entries, generation));
    });
  }

  Future<void> _warmRemainingDictionaries(
    List<DictionaryLibraryEntry> entries,
    int generation,
  ) async {
    for (final entry in entries) {
      if (!mounted || generation != _dictionaryWarmupGeneration) {
        return;
      }
      if (!entry.isEnabled ||
          _availableMdxPaths.contains(entry.mdxPath) ||
          _failedMdxPaths.contains(entry.mdxPath)) {
        continue;
      }
      if (_isSearching || _isImporting) {
        _scheduleDictionaryWarmup(
          entries,
          delay: const Duration(seconds: 4),
        );
        return;
      }

      final prepared = await _prepareDictionary(entry);
      if (!mounted || generation != _dictionaryWarmupGeneration) {
        return;
      }
      if (!prepared) {
        continue;
      }
      setState(() {
        _availableMdxPaths = {..._availableMdxPaths, entry.mdxPath};
      });

      // If a word is already open, quietly fill in the newly warmed
      // dictionary without restarting the visible lookup or moving selection.
      final query = _queryController.text.trim();
      final request = _lookupRequest;
      if (query.isEmpty) {
        continue;
      }
      try {
        final articles = await _resolveArticles(entry, query);
        if (!mounted ||
            generation != _dictionaryWarmupGeneration ||
            request != _lookupRequest ||
            query != _queryController.text.trim()) {
          return;
        }
        setState(() {
          _articlesByDictionary = {
            ..._articlesByDictionary,
            entry.mdxPath: articles,
          };
        });
        final selectedPath = _selectedMdxPath;
        if (selectedPath != null) {
          _preloadNextDictionaryReader(selectedPath);
        }
      } catch (_) {
        // The dictionary remains available; an individual lookup miss or
        // decode failure must not undo a successfully restored source.
      }
    }
    if (mounted && generation == _dictionaryWarmupGeneration) {
      _scheduleIndexMigration(entries);
    }
  }

  Future<void> _selectDictionary(DictionaryLibraryEntry entry) async {
    if (!_availableMdxPaths.contains(entry.mdxPath)) {
      setState(() => _isImporting = true);
      final prepared = await _prepareDictionary(entry);
      if (!mounted) {
        return;
      }
      setState(() {
        _isImporting = false;
        if (prepared) {
          _availableMdxPaths = {..._availableMdxPaths, entry.mdxPath};
        }
      });
      if (!prepared) {
        _showMessage('无法打开「${entry.title}」。文件可能已移动，或需要重新导入以授予访问权限。');
        return;
      }
    }

    _rememberCurrentReaderPosition();
    setState(() {
      final previous = _selectedMdxPath;
      _selectedMdxPath = entry.mdxPath;
      _retainedReaderPaths = _adoptRetainedReaderPaths(
        _retainReaderPath(
          _retainReaderPath(_retainedReaderPaths, previous),
          entry.mdxPath,
        ),
      );
      _articleAnchor = null;
      _articleScrollOffset = null;
    });
    if (_readerPlatformPolicy.aggregateDictionaryResults) {
      unawaited(_aggregateArticleController.showDictionary(entry.mdxPath));
    }
    final query = _queryController.text.trim();
    if (query.isNotEmpty && !_articlesByDictionary.containsKey(entry.mdxPath)) {
      await _lookup(query, preferredMdxPath: entry.mdxPath);
    }
  }

  Future<void> _remove(DictionaryLibraryEntry entry) async {
    _rememberCurrentReaderPosition();
    final entries = await widget.library.remove(entry.mdxPath);
    if (!mounted) {
      return;
    }
    final wasSelected = _selectedMdxPath == entry.mdxPath;
    setState(() {
      _libraryEntries = entries;
      _availableMdxPaths = {..._availableMdxPaths}..remove(entry.mdxPath);
      _failedMdxPaths.remove(entry.mdxPath);
      _articlesByDictionary = {..._articlesByDictionary}..remove(entry.mdxPath);
      if (wasSelected) {
        _selectedMdxPath = dictionaryEntriesForScope(
          entries.where(
            (candidate) =>
                candidate.isEnabled &&
                _availableMdxPaths.contains(candidate.mdxPath),
          ),
          _activeDictionaryScopeId,
        ).map((candidate) => candidate.mdxPath).firstOrNull;
        _articleAnchor = null;
        _articleScrollOffset = null;
      }
      var retained = _retainedReaderPaths
          .where((path) => path != entry.mdxPath)
          .toList(growable: false);
      if (_selectedMdxPath case final selectedPath?) {
        retained = _retainReaderPath(retained, selectedPath);
      }
      _retainedReaderPaths = _adoptRetainedReaderPaths(retained);
    });
    _readerPositionCache.removeDictionary(entry.mdxPath);
    if (_availableMdxPaths.isEmpty) {
      widget.engine.clearActiveDictionary();
    }
    try {
      _fileAccess.unregisterSource(entry.mdxPath);
      final folderIsStillUsed = entries.any(
        (candidate) => candidate.accessPath == entry.accessPath,
      );
      if (!folderIsStillUsed) {
        await _fileAccess.revoke(entry.accessPath);
      }
    } catch (_) {
      if (mounted) {
        _showMessage('已移除词典库记录；撤销本机文件授权时出现问题。');
      }
    }
  }

  Future<bool> _renameDictionary(
    BuildContext dialogHostContext,
    DictionaryLibraryEntry entry,
  ) async {
    final submitted = await showDialog<String>(
      context: dialogHostContext,
      builder: (_) => _RenameDictionaryDialog(
        initialName: entry.title,
      ),
    );
    final title = submitted?.trim();
    if (title == null || title.isEmpty || title == entry.title) return false;
    try {
      final entries = await widget.library.upsert(entry.copyWith(title: title));
      if (!mounted) return false;
      setState(() => _libraryEntries = entries);
      _showMessage('词典显示名称已修改为“$title”。');
      return true;
    } catch (_) {
      if (mounted) _showMessage('无法保存词典显示名称。');
      return false;
    }
  }

  String _dictionaryScopeName(String scopeId) {
    if (scopeId == DictionaryGroupScope.all) return '全部词典';
    if (scopeId == DictionaryGroupScope.ungrouped) return '未分组';
    return _dictionaryGroupSnapshot.groups
            .where((group) => group.id == scopeId)
            .map((group) => group.name)
            .firstOrNull ??
        '全部词典';
  }

  String? _dictionaryGroupNameError(
    String rawName, {
    String? excludingGroupId,
  }) {
    final name = rawName.trim();
    if (name.isEmpty) return '分组名称不能为空';
    if (name.length > 30) return '分组名称不能超过 30 个字符';
    final normalized = name.toLowerCase();
    if (normalized == '全部词典' || normalized == '未分组') {
      return '这是系统保留名称';
    }
    final duplicate = _dictionaryGroupSnapshot.groups.any(
      (group) =>
          group.id != excludingGroupId &&
          group.name.trim().toLowerCase() == normalized,
    );
    return duplicate ? '已经存在同名分组' : null;
  }

  String _newDictionaryGroupId() {
    final existing =
        _dictionaryGroupSnapshot.groups.map((group) => group.id).toSet();
    final seed = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    var suffix = 0;
    var candidate = 'group-$seed';
    while (existing.contains(candidate)) {
      suffix++;
      candidate = 'group-$seed-$suffix';
    }
    return candidate;
  }

  Future<void> _showCreateDictionaryGroup() async {
    if (!_supportsDictionaryGroups) return;
    final nameController = TextEditingController();
    var step = 1;
    String? errorText;
    var selectedColorIndex = _dictionaryGroupSnapshot.groups.length %
        DictionaryGroup.colorChoiceCount;
    final selectedPaths = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final selectedCount = selectedPaths.length;
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: SafeArea(
              top: false,
              child: FractionallySizedBox(
                heightFactor: 0.78,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              step == 1 ? '新建分组' : '选择要移入的词典',
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          Text('$step / 2'),
                        ],
                      ),
                    ),
                    if (step == 1)
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                          children: [
                            TextField(
                              controller: nameController,
                              autofocus: true,
                              maxLength: 30,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: '分组名称',
                                hintText: '例如：英语、汉英、日语',
                                errorText: errorText,
                                helperText: '只用于整理词典，不会修改词典文件。',
                              ),
                              onSubmitted: (_) {
                                final error = _dictionaryGroupNameError(
                                  nameController.text,
                                );
                                setSheetState(() {
                                  errorText = error;
                                  if (error == null) step = 2;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '文件夹颜色',
                              style: Theme.of(sheetContext)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (var colorIndex = 0;
                                    colorIndex <
                                        DictionaryGroup.colorChoiceCount;
                                    colorIndex++)
                                  ChoiceChip(
                                    selected: selectedColorIndex == colorIndex,
                                    avatar: Icon(
                                      Icons.folder_rounded,
                                      size: 18,
                                      color: _dictionaryGroupColors[colorIndex],
                                    ),
                                    label: Text(
                                      _dictionaryGroupColorNames[colorIndex],
                                    ),
                                    onSelected: (_) => setSheetState(
                                      () => selectedColorIndex = colorIndex,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      )
                    else
                      Expanded(
                        child: _libraryEntries.isEmpty
                            ? const Center(child: Text('当前没有可加入分组的词典。'))
                            : ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                itemCount: _libraryEntries.length,
                                itemBuilder: (context, index) {
                                  final entry = _libraryEntries[index];
                                  final checked =
                                      selectedPaths.contains(entry.mdxPath);
                                  final currentGroup = entry.groupId == null
                                      ? '未分组'
                                      : _dictionaryScopeName(entry.groupId!);
                                  return CheckboxListTile(
                                    value: checked,
                                    title: Text(
                                      entry.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text('当前：$currentGroup'),
                                    onChanged: (selected) {
                                      setSheetState(() {
                                        if (selected ?? false) {
                                          selectedPaths.add(entry.mdxPath);
                                        } else {
                                          selectedPaths.remove(entry.mdxPath);
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              if (step == 1) {
                                Navigator.of(sheetContext).pop();
                              } else {
                                setSheetState(() => step = 1);
                              }
                            },
                            child: Text(step == 1 ? '取消' : '上一步'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () async {
                              if (step == 1) {
                                final error = _dictionaryGroupNameError(
                                  nameController.text,
                                );
                                setSheetState(() {
                                  errorText = error;
                                  if (error == null) step = 2;
                                });
                                return;
                              }
                              final created = await _createDictionaryGroup(
                                nameController.text.trim(),
                                selectedPaths,
                                colorIndex: selectedColorIndex,
                              );
                              if (created && sheetContext.mounted) {
                                Navigator.of(sheetContext).pop();
                              }
                            },
                            child: Text(
                              step == 1
                                  ? '下一步'
                                  : selectedCount == 0
                                      ? '创建空分组'
                                      : '创建并移动 $selectedCount 本',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    nameController.dispose();
  }

  Future<bool> _createDictionaryGroup(
    String name,
    Set<String> selectedPaths, {
    required int colorIndex,
  }) async {
    if (_dictionaryGroupNameError(name) != null) return false;
    final previousSnapshot = _dictionaryGroupSnapshot;
    final previousEntries = List<DictionaryLibraryEntry>.of(_libraryEntries);
    final nextOrder = previousSnapshot.groups.isEmpty
        ? 0
        : previousSnapshot.groups
                .map((group) => group.sortOrder)
                .reduce((left, right) => left > right ? left : right) +
            1;
    final group = DictionaryGroup(
      id: _newDictionaryGroupId(),
      name: name.trim(),
      sortOrder: nextOrder,
      colorIndex: colorIndex,
    );
    final nextSnapshot = previousSnapshot.copyWith(
      groups: [...previousSnapshot.groups, group],
    );
    final nextEntries = previousEntries
        .map(
          (entry) => selectedPaths.contains(entry.mdxPath)
              ? entry.copyWith(groupId: group.id)
              : entry,
        )
        .toList(growable: false);
    try {
      await widget.dictionaryGroups.save(nextSnapshot);
      try {
        await widget.library.replaceAll(nextEntries);
      } catch (_) {
        await widget.dictionaryGroups.save(previousSnapshot);
        rethrow;
      }
      if (!mounted) return true;
      setState(() {
        _dictionaryGroupSnapshot = nextSnapshot;
        _libraryEntries = nextEntries;
      });
      await _reconcileLookupAfterGroupingChange();
      if (mounted) {
        _showMessage(
          selectedPaths.isEmpty
              ? '已创建分组“${group.name}”。'
              : '已创建分组“${group.name}”，并移入 ${selectedPaths.length} 本词典。',
        );
      }
      return true;
    } catch (_) {
      if (mounted) _showMessage('无法保存新分组。');
      return false;
    }
  }

  Future<void> _renameDictionaryGroup(DictionaryGroup group) async {
    final submitted = await showDialog<String>(
      context: context,
      builder: (_) => _DictionaryGroupNameDialog(
        title: '重命名分组',
        initialName: group.name,
        validator: (value) => _dictionaryGroupNameError(
          value,
          excludingGroupId: group.id,
        ),
      ),
    );
    final name = submitted?.trim();
    if (name == null || name == group.name) return;
    final next = _dictionaryGroupSnapshot.copyWith(
      groups: _dictionaryGroupSnapshot.groups
          .map((candidate) => candidate.id == group.id
              ? candidate.copyWith(name: name)
              : candidate)
          .toList(growable: false),
    );
    try {
      await widget.dictionaryGroups.save(next);
      if (!mounted) return;
      setState(() => _dictionaryGroupSnapshot = next);
      _showMessage('分组已重命名为“$name”。');
    } catch (_) {
      if (mounted) _showMessage('无法保存分组名称。');
    }
  }

  Color _dictionaryGroupColor(DictionaryGroup group) =>
      _dictionaryGroupColors[group.colorIndex.clamp(
        0,
        DictionaryGroup.colorChoiceCount - 1,
      )];

  Future<void> _changeDictionaryGroupColor(DictionaryGroup group) async {
    final selectedColorIndex = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('“${group.name}”的文件夹颜色'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var index = 0;
                index < DictionaryGroup.colorChoiceCount;
                index++)
              ChoiceChip(
                selected: group.colorIndex == index,
                avatar: Icon(
                  Icons.folder_rounded,
                  size: 18,
                  color: _dictionaryGroupColors[index],
                ),
                label: Text(_dictionaryGroupColorNames[index]),
                onSelected: (_) => Navigator.of(dialogContext).pop(index),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selectedColorIndex == null || selectedColorIndex == group.colorIndex) {
      return;
    }
    final next = _dictionaryGroupSnapshot.copyWith(
      groups: _dictionaryGroupSnapshot.groups
          .map(
            (candidate) => candidate.id == group.id
                ? candidate.copyWith(colorIndex: selectedColorIndex)
                : candidate,
          )
          .toList(growable: false),
    );
    try {
      await widget.dictionaryGroups.save(next);
      if (!mounted) return;
      setState(() => _dictionaryGroupSnapshot = next);
    } catch (_) {
      if (mounted) _showMessage('无法保存分组颜色。');
    }
  }

  Future<void> _deleteDictionaryGroup(DictionaryGroup group) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('删除“${group.name}”？'),
            content: const Text('分组中的词典会移到“未分组”，词典文件和查词记录都不会删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('删除分组'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final previousEntries = List<DictionaryLibraryEntry>.of(_libraryEntries);
    final previousSnapshot = _dictionaryGroupSnapshot;
    final nextEntries = previousEntries
        .map((entry) => entry.groupId == group.id
            ? entry.copyWith(clearGroupId: true)
            : entry)
        .toList(growable: false);
    final nextSnapshot = DictionaryGroupSnapshot(
      groups: previousSnapshot.groups
          .where((candidate) => candidate.id != group.id)
          .toList(growable: false),
      activeScopeId: previousSnapshot.activeScopeId == group.id
          ? DictionaryGroupScope.all
          : previousSnapshot.activeScopeId,
    );
    try {
      await widget.library.replaceAll(nextEntries);
      try {
        await widget.dictionaryGroups.save(nextSnapshot);
      } catch (_) {
        await widget.library.replaceAll(previousEntries);
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _libraryEntries = nextEntries;
        _dictionaryGroupSnapshot = nextSnapshot;
      });
      await _reconcileLookupAfterGroupingChange();
      if (mounted) _showMessage('分组已删除，原有词典已移到“未分组”。');
    } catch (_) {
      if (mounted) _showMessage('无法删除分组。');
    }
  }

  Future<void> _showMoveDictionaryToGroup(
    DictionaryLibraryEntry entry,
  ) async {
    final targetGroupId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
              child: Text(
                '移动“${entry.title}”',
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('未分组'),
              trailing: entry.groupId == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(sheetContext)
                  .pop(DictionaryGroupScope.ungrouped),
            ),
            for (final group in _dictionaryGroupSnapshot.groups)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(group.name),
                trailing: entry.groupId == group.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(group.id),
              ),
          ],
        ),
      ),
    );
    if (targetGroupId == null) return;
    final nextEntry = targetGroupId == DictionaryGroupScope.ungrouped
        ? entry.copyWith(clearGroupId: true)
        : entry.copyWith(groupId: targetGroupId);
    if (nextEntry.groupId == entry.groupId) return;
    try {
      final entries = await widget.library.upsert(nextEntry);
      if (!mounted) return;
      setState(() => _libraryEntries = entries);
      await _reconcileLookupAfterGroupingChange();
      if (mounted) {
        _showMessage(
            '“${entry.title}”已移到${_dictionaryScopeName(targetGroupId)}。');
      }
    } catch (_) {
      if (mounted) _showMessage('无法移动词典。');
    }
  }

  Future<void> _reconcileLookupAfterGroupingChange() async {
    if (_activeDictionaryScopeId == DictionaryGroupScope.all) return;
    final entries = _availableEntries;
    final selectedStillVisible =
        entries.any((entry) => entry.mdxPath == _selectedMdxPath);
    final nextSelected = selectedStillVisible
        ? _selectedMdxPath
        : entries
                .where((entry) =>
                    _articlesByDictionary[entry.mdxPath]?.isNotEmpty ?? false)
                .map((entry) => entry.mdxPath)
                .firstOrNull ??
            entries.map((entry) => entry.mdxPath).firstOrNull;
    if (mounted) {
      setState(() {
        _selectedMdxPath = nextSelected;
        if (nextSelected == null) _articlesByDictionary = const {};
      });
    }
    final query = _queryController.text.trim();
    if (query.isNotEmpty && entries.isNotEmpty) {
      await _lookup(query, preferredMdxPath: nextSelected);
    }
  }

  Future<void> _selectDictionaryScope(String scopeId) async {
    if (!_supportsDictionaryGroups || scopeId == _activeDictionaryScopeId) {
      return;
    }
    final valid = DictionaryGroupScope.isSystem(scopeId) ||
        _dictionaryGroupSnapshot.groups.any((group) => group.id == scopeId);
    if (!valid) return;
    final nextSnapshot = _dictionaryGroupSnapshot.copyWith(
      activeScopeId: scopeId,
    );
    try {
      await widget.dictionaryGroups.save(nextSnapshot);
    } catch (_) {
      if (mounted) _showMessage('无法保存当前查词分组。');
      return;
    }
    if (!mounted) return;
    _rememberCurrentReaderPosition();
    setState(() {
      _dictionaryGroupSnapshot = nextSnapshot;
      _suggestions = const [];
      _selectedSuggestionIndex = -1;
    });

    var entries = _availableEntries;
    if (entries.isEmpty) {
      final firstCandidate = dictionaryEntriesForScope(
        _libraryEntries.where((entry) => entry.isEnabled),
        scopeId,
      ).firstOrNull;
      if (firstCandidate != null && await _prepareDictionary(firstCandidate)) {
        if (!mounted) return;
        setState(() {
          _availableMdxPaths = {..._availableMdxPaths, firstCandidate.mdxPath};
        });
        entries = _availableEntries;
      }
    }
    final nextSelected = entries
            .where((entry) =>
                _articlesByDictionary[entry.mdxPath]?.isNotEmpty ?? false)
            .map((entry) => entry.mdxPath)
            .firstOrNull ??
        entries.map((entry) => entry.mdxPath).firstOrNull;
    setState(() {
      _selectedMdxPath = nextSelected;
      _articleAnchor = null;
      _articleScrollOffset = null;
      if (entries.isEmpty) _articlesByDictionary = const {};
    });
    final query = _queryController.text.trim();
    if (query.isNotEmpty && entries.isNotEmpty) {
      await _lookup(query, preferredMdxPath: nextSelected);
    }
  }

  Future<void> _showLibrary() async {
    var entries = _libraryEntries;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SizedBox(
              height: 440,
              child: entries.isEmpty
                  ? const Center(child: Text('词典库为空。请先导入一个 MDX 文件。'))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final isActive = entry.mdxPath == _selectedMdxPath;
                        final isAvailable =
                            _availableMdxPaths.contains(entry.mdxPath);
                        return ListTile(
                          key: ValueKey(entry.mdxPath),
                          leading: Icon(
                            isActive
                                ? Icons.check_circle
                                : Icons.menu_book_outlined,
                          ),
                          title: Text(entry.title),
                          subtitle: Text(
                            '${entry.mdxPath}\n${entry.isEnabled ? '参与查询' : '已停用'}${isAvailable ? '' : ' · 文件暂时无法访问'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: _isImporting || !entry.isEnabled
                              ? null
                              : () {
                                  Navigator.of(sheetContext).pop();
                                  _selectDictionary(entry);
                                },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: entry.isEnabled ? '停止参与查询' : '参与查询',
                                child: Switch(
                                  value: entry.isEnabled,
                                  onChanged: _isImporting
                                      ? null
                                      : (enabled) async {
                                          await _setDictionaryEnabled(
                                            entry,
                                            enabled,
                                          );
                                          entries = _libraryEntries;
                                          if (sheetContext.mounted) {
                                            setSheetState(() {});
                                          }
                                        },
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: '更多词典操作',
                                icon: const Icon(Icons.more_vert),
                                onSelected: (action) async {
                                  if (action == 'rename') {
                                    await _renameDictionary(
                                      sheetContext,
                                      entry,
                                    );
                                  } else if (action == 'remove') {
                                    await _remove(entry);
                                  }
                                  entries = _libraryEntries;
                                  if (sheetContext.mounted) {
                                    setSheetState(() {});
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('修改显示名称'),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(Icons.delete_outline),
                                      title: Text('从词典库移除'),
                                    ),
                                  ),
                                ],
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                      onReorderItem: (oldIndex, newIndex) async {
                        final reordered = List.of(entries);
                        final moved = reordered.removeAt(oldIndex);
                        reordered.insert(newIndex, moved);
                        entries = reordered;
                        setSheetState(() {});
                        if (mounted) {
                          setState(() => _libraryEntries = reordered);
                        }
                        try {
                          final saved = await widget.library.reorder(
                            reordered.map((entry) => entry.mdxPath).toList(),
                          );
                          entries = saved;
                          if (mounted) {
                            setState(() => _libraryEntries = saved);
                          }
                        } catch (_) {
                          if (mounted) {
                            _showMessage('无法保存词典顺序。');
                          }
                        }
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showAppDiagnostics() async {
    await showAppDiagnosticsSheet(
      context,
      loadReport: () => _appDiagnostics.collect(
        dictionaryCount: _libraryEntries.length,
        enabledDictionaryCount:
            _libraryEntries.where((entry) => entry.isEnabled).length,
        availableDictionaryCount: _availableMdxPaths.length,
        historyCount: _history.length,
        favoriteCount: _favorites.length,
        reviewCardCount: _reviewCards.length,
      ),
      saveDiagnostics: _saveDiagnosticsReport,
      clearDiagnostics: _appDiagnostics.clearReaderEvents,
      exportLearningData: _exportLearningData,
      importLearningData: _importLearningData,
    );
  }

  Future<void> _saveDiagnosticsReport(AppDiagnosticsReport report) async {
    final stamp = report.generatedAt
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final saved = await FilePicker.saveFile(
      dialogTitle: '保存 LumaLex 诊断报告',
      fileName: 'LumaLex-diagnostics-$stamp.txt',
      bytes: Uint8List.fromList(utf8.encode(report.toText())),
      mimeType: 'text/plain',
    );
    if (saved != null && mounted) {
      _showMessage('诊断报告已保存。');
    }
  }

  Future<void> _saveWindowsDiagnosticsReport() async {
    final generatedAt = DateTime.now();
    final events = await ReaderDiagnostics.instance.readLines();
    final report = <String>[
      'LumaLex $desktopPlatformName diagnostics',
      'Generated: ${generatedAt.toUtc().toIso8601String()}',
      'App: $lumalexDisplayVersion',
      'Operating system: ${Platform.operatingSystemVersion}',
      'Close behavior: ${_windowsCloseBehavior.name}',
      'Dictionaries: ${_availableMdxPaths.length} available / '
          '${_libraryEntries.where((entry) => entry.isEnabled).length} enabled / '
          '${_libraryEntries.length} managed',
      'Word records: ${_history.length} history / '
          '${_favorites.length} favorites / '
          '${_reviewCards.length} review cards',
      'Text scale: ${(_textScale * 100).round()}%',
      '',
      'Reader events (${events.length})',
      if (events.isEmpty) '(none)' else ...events,
      '',
    ].join('\n');
    final stamp = generatedAt
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final saved = await FilePicker.saveFile(
      dialogTitle: '保存 LumaLex $desktopPlatformName 诊断报告',
      fileName: 'LumaLex-$desktopPlatformName-diagnostics-$stamp.txt',
      bytes: Uint8List.fromList(utf8.encode(report)),
      mimeType: 'text/plain',
    );
    if (saved != null && mounted) {
      _showMessage('诊断报告已保存。');
    }
  }

  Future<void> _exportLearningData() async {
    final backup = LearningDataBackup(
      exportedAt: DateTime.now(),
      history: _history,
      favorites: _favorites,
      reviewCards: _reviewCards,
      textScale: _textScale,
    );
    final day = DateTime.now().toIso8601String().split('T').first;
    final saved = await FilePicker.saveFile(
      dialogTitle: '导出 LumaLex 学习数据',
      fileName: 'LumaLex-learning-data-$day.json',
      bytes: Uint8List.fromList(utf8.encode(backup.encode())),
      mimeType: 'application/json',
    );
    if (saved != null && mounted) {
      _showMessage('学习数据已导出；文件中不包含词典内容。');
    }
  }

  Future<void> _importLearningData() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择 LumaLex 学习数据',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;
    try {
      final backup = LearningDataBackup.decode(
        utf8.decode(await picked.readAsBytes()),
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('恢复学习数据？'),
              content: Text(
                '将用备份中的 ${backup.history.length} 条历史、'
                '${backup.favorites.length} 个收藏和 '
                '${backup.reviewCards.length} 张复习卡片替换当前学习记录。'
                '词典文件和词典库不会改变。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('恢复'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) return;
      final cards = synchronizeReviewCards(
        backup.favorites,
        backup.reviewCards,
        now: DateTime.now(),
      );
      await Future.wait([
        widget.wordRecords.saveHistory(backup.history),
        widget.wordRecords.saveFavorites(backup.favorites),
        widget.wordRecords.saveReviewCards(cards),
        widget.wordRecords.saveTextScale(backup.textScale),
      ]);
      if (!mounted) return;
      _wordRecordsMutationGeneration++;
      _readerPositionCache.clear();
      setState(() {
        _history = backup.history;
        _favorites = backup.favorites;
        _reviewCards = cards;
        _textScale = backup.textScale;
        _reviewAnswerVisible = false;
      });
      _showMessage('学习数据已恢复。');
    } on FormatException catch (error) {
      if (mounted) _showMessage('无法恢复学习数据：${error.message}');
    } catch (error) {
      debugPrint('Learning data import failed: $error');
      if (mounted) _showMessage('无法读取或保存这份学习数据。');
    }
  }

  Future<void> _setDictionaryEnabled(
    DictionaryLibraryEntry entry,
    bool enabled,
  ) async {
    if (enabled && !_availableMdxPaths.contains(entry.mdxPath)) {
      setState(() => _isImporting = true);
      final prepared = await _prepareDictionary(entry);
      if (!mounted) {
        return;
      }
      setState(() {
        _isImporting = false;
        if (prepared) {
          _availableMdxPaths = {..._availableMdxPaths, entry.mdxPath};
        }
      });
      if (!prepared) {
        _showMessage('无法打开「${entry.title}」。请重新导入以恢复文件访问。');
        return;
      }
    }
    final entries = await widget.library.upsert(
      entry.copyWith(isEnabled: enabled),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _libraryEntries = entries;
      if (enabled) {
        if (_entryMatchesActiveDictionaryScope(entry)) {
          _selectedMdxPath ??= entry.mdxPath;
        }
      } else if (_selectedMdxPath == entry.mdxPath) {
        _selectedMdxPath = dictionaryEntriesForScope(
          entries.where(
            (candidate) =>
                candidate.isEnabled &&
                _availableMdxPaths.contains(candidate.mdxPath),
          ),
          _activeDictionaryScopeId,
        ).map((candidate) => candidate.mdxPath).firstOrNull;
        _articleAnchor = null;
        _articleScrollOffset = null;
      }
    });
    final query = _queryController.text.trim();
    if (query.isNotEmpty && _availableEntries.isNotEmpty) {
      await _lookup(query, preferredMdxPath: _selectedMdxPath);
    } else if (_availableEntries.isEmpty && mounted) {
      setState(() => _articlesByDictionary = const {});
    }
  }

  double get _currentTextScale => _textScale;

  void _setCurrentTextScale(double scale) {
    final updated = scale.clamp(0.6, 2.0).toDouble();
    if (updated != _textScale) {
      // Pixel offsets are not stable across a full-document text reflow.
      // Retained WKWebViews preserve their own live positions; discard only
      // the offsets for readers that were already evicted.
      _readerPositionCache.clear();
    }
    setState(() => _textScale = updated);
    if (_showReaderTextControls) {
      _scheduleReaderTextControlsHide();
    }
    widget.wordRecords.saveTextScale(updated).catchError((Object _) {
      if (mounted) {
        _showMessage('字号已调整，但无法保存全局字号设置。');
      }
    });
  }

  void _focusSearchField() {
    _searchFocusNode.requestFocus();
    _queryController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _queryController.text.length,
    );
  }

  void _toggleFavoriteShortcut() {
    final query = _queryController.text.trim();
    if (query.isNotEmpty) {
      unawaited(_toggleFavorite(query));
    }
  }

  void _goBackShortcut() {
    if (_lookupNavigation.canGoBack && !_isSearching) {
      unawaited(_goBack());
    }
  }

  void _goForwardShortcut() {
    if (_lookupNavigation.canGoForward && !_isSearching) {
      unawaited(_goForward());
    }
  }

  void _escapeShortcut() {
    if (_showSettingsPage) {
      _closeSettings();
      return;
    }
    if (_suggestions.isNotEmpty) {
      setState(() {
        _suggestions = const [];
        _selectedSuggestionIndex = -1;
      });
      return;
    }
    _searchFocusNode.unfocus();
  }

  KeyEventResult _handleSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _suggestions.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedSuggestionIndex =
            (_selectedSuggestionIndex + 1) % _suggestions.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedSuggestionIndex =
            (_selectedSuggestionIndex - 1 + _suggestions.length) %
                _suggestions.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final index =
          _selectedSuggestionIndex.clamp(0, _suggestions.length - 1).toInt();
      _activateSuggestion(_suggestions[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activateSuggestion(String suggestion) {
    _queryController.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    unawaited(_startNewLookup(suggestion));
  }

  void _selectDestination(_AppDestination destination) {
    if (_destination != destination || _showSettingsPage) {
      setState(() {
        _destination = destination;
        _showSettingsPage = false;
      });
    }
  }

  void _showSettings() {
    if (!_showSettingsPage) {
      setState(() => _showSettingsPage = true);
    }
  }

  void _closeSettings() {
    if (_showSettingsPage) {
      setState(() => _showSettingsPage = false);
    }
  }

  bool get _hasVisibleReaderArticle {
    final selectedPath = _selectedMdxPath;
    if (selectedPath == null) {
      return false;
    }
    return _articlesByDictionary[selectedPath]?.isNotEmpty ?? false;
  }

  void _clearLookup() {
    _readerControlsTimer?.cancel();
    _searchFocusNode.unfocus();
    _queryController.clear();
    setState(() {
      _lookupNavigation.clear();
      _showReaderTextControls = false;
    });
    _suggest('');
    unawaited(_lookup(''));
  }

  void _toggleReaderTextControls() {
    if (!_hasVisibleReaderArticle) return;
    _readerControlsTimer?.cancel();
    _searchFocusNode.unfocus();
    final show = !_showReaderTextControls;
    setState(() {
      _showReaderTextControls = show;
      if (widget.processTextMode) {
        _suggestions = const [];
        _selectedSuggestionIndex = -1;
      }
    });
    if (show) {
      _scheduleReaderTextControlsHide();
    }
  }

  void _scheduleReaderTextControlsHide() {
    _readerControlsTimer?.cancel();
    _readerControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _showReaderTextControls) {
        setState(() => _showReaderTextControls = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.processTextMode) {
      return _buildProcessTextShell();
    }
    final shell = LayoutBuilder(
      builder: (context, constraints) {
        final useSideRail = constraints.maxWidth >= 600;
        final expandSideRail = constraints.maxWidth >= 1080;
        final railColorScheme = Theme.of(context).colorScheme;
        final expandedRailLabelStyle = TextStyle(
          fontSize: 17,
          height: 1.2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
          color: railColorScheme.onSurfaceVariant,
        );
        // Foldable cover displays are often as narrow as a phone but notably
        // shorter. Keep their secondary pages content-first without changing
        // the normal phone or tablet layouts.
        final useShortMobileLayout =
            !useSideRail && constraints.maxHeight < 640;
        final compactReader = !_showSettingsPage &&
            !useSideRail &&
            _destination == _AppDestination.lookup &&
            _hasVisibleReaderArticle;
        final destinationContent = _buildDestinationPages(
          compact: !useSideRail,
          shortMobile: useShortMobileLayout,
        );
        // Settings is a temporary overlay destination, not a replacement for
        // the three primary pages. Keep the destination stack mounted while
        // settings is visible so the lookup WebView, its DOM and its scroll
        // position survive the round trip without another document load.
        final content = IndexedStack(
          index: _showSettingsPage ? 1 : 0,
          sizing: StackFit.expand,
          children: [
            KeyedSubtree(
              key: const ValueKey<String>('primary-destination-content'),
              child: destinationContent,
            ),
            KeyedSubtree(
              key: const ValueKey<String>('settings-destination-content'),
              child: _buildSettingsPage(),
            ),
          ],
        );
        return Scaffold(
          // Lookup is a reader, not a conventional app page. Its own compact
          // search header replaces the generic title bar on phones so the
          // dictionary entry gets the screen first.
          appBar: useSideRail
              ? null
              : _showSettingsPage
                  ? _buildSettingsAppBar()
                  : _destination == _AppDestination.lookup
                      ? null
                      : _buildCompactAppBar(
                          shortMobile: useShortMobileLayout,
                        ),
          body: useSideRail
              ? Row(
                  children: [
                    SafeArea(
                      right: false,
                      child: LayoutBuilder(
                        builder: (context, railConstraints) => Column(
                          children: [
                            Expanded(
                              child: NavigationRail(
                                scrollable: true,
                                extended: expandSideRail,
                                minExtendedWidth: expandSideRail ? 244 : 220,
                                selectedIconTheme: expandSideRail
                                    ? IconThemeData(
                                        size: 32,
                                        color: railColorScheme.primary,
                                      )
                                    : null,
                                unselectedIconTheme: expandSideRail
                                    ? IconThemeData(
                                        size: 30,
                                        color: railColorScheme.onSurfaceVariant,
                                      )
                                    : null,
                                selectedLabelTextStyle: expandSideRail
                                    ? expandedRailLabelStyle.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: railColorScheme.onSurface,
                                      )
                                    : null,
                                unselectedLabelTextStyle: expandSideRail
                                    ? expandedRailLabelStyle
                                    : null,
                                selectedIndex: _showSettingsPage
                                    ? null
                                    : _destination.index,
                                onDestinationSelected: (index) =>
                                    _selectDestination(
                                  _AppDestination.values[index],
                                ),
                                leading: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    expandSideRail ? 16 : 12,
                                    12,
                                    expandSideRail ? 16 : 12,
                                    expandSideRail ? 30 : 26,
                                  ),
                                  child: _buildRailBrand(
                                    expanded: expandSideRail,
                                  ),
                                ),
                                destinations: const [
                                  NavigationRailDestination(
                                    icon: Icon(Icons.search_rounded),
                                    selectedIcon: Icon(Icons.search_rounded),
                                    label: Text('查词'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(Icons.auto_stories_outlined),
                                    selectedIcon:
                                        Icon(Icons.auto_stories_rounded),
                                    label: Text('词汇本'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(Icons.library_books_outlined),
                                    selectedIcon:
                                        Icon(Icons.library_books_rounded),
                                    label: Text('词典'),
                                  ),
                                ],
                                trailing: isLumaLexDesktop
                                    ? _buildDesktopDictionaryRail(
                                        expanded: expandSideRail,
                                        availableHeight:
                                            railConstraints.maxHeight,
                                      )
                                    : null,
                                trailingAtBottom:
                                    railConstraints.maxHeight < 700,
                              ),
                            ),
                            if (isLumaLexDesktop)
                              _buildSettingsNavigationButton(
                                expanded: expandSideRail,
                              ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: SafeArea(child: content)),
                  ],
                )
              : SafeArea(top: false, child: content),
          // Keep the app destinations available when searching or managing
          // the library. Once an article is open, this is a focused reading
          // view; the back affordance beside the search field restores it.
          bottomNavigationBar: useSideRail || compactReader || _showSettingsPage
              ? null
              : NavigationBar(
                  selectedIndex: _destination.index,
                  onDestinationSelected: (index) => _selectDestination(
                    _AppDestination.values[index],
                  ),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.search_outlined),
                      selectedIcon: Icon(Icons.search_rounded),
                      label: '查词',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.auto_stories_outlined),
                      selectedIcon: Icon(Icons.auto_stories_rounded),
                      label: '词汇本',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_books_outlined),
                      selectedIcon: Icon(Icons.library_books_rounded),
                      label: '词典',
                    ),
                  ],
                ),
        );
      },
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true):
            _focusSearchField,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true):
            _focusSearchField,
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            _toggleFavoriteShortcut,
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            _toggleFavoriteShortcut,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true):
            _goBackShortcut,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
            _goBackShortcut,
        const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true):
            _goForwardShortcut,
        const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
            _goForwardShortcut,
        const SingleActivator(LogicalKeyboardKey.pageUp, control: true): () =>
            _switchDictionaryResult(forward: false),
        const SingleActivator(LogicalKeyboardKey.pageDown, control: true): () =>
            _switchDictionaryResult(forward: true),
        const SingleActivator(LogicalKeyboardKey.escape): _escapeShortcut,
      },
      child: Focus(autofocus: true, child: shell),
    );
  }

  Widget _buildProcessTextShell() {
    final colors = Theme.of(context).colorScheme;
    final shell = Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21),
          child: Scaffold(
            backgroundColor: colors.surface,
            body: Column(
              children: [
                _buildProcessTextTitleBar(),
                Divider(height: 1, color: colors.outlineVariant),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildLookupPage(compact: true),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: _buildProcessTextResizeHandle(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          unawaited(AndroidProcessTextWindow.close());
        },
      },
      child: Focus(autofocus: true, child: shell),
    );
  }

  Widget _buildProcessTextTitleBar() {
    final colors = Theme.of(context).colorScheme;
    final favorite = _isFavorite(_queryController.text);
    final hasArticle = _hasVisibleReaderArticle;
    return SizedBox(
      height: 50,
      child: Row(
        children: [
          const SizedBox(width: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/branding/lumalex-icon-ui.png',
              width: 28,
              height: 28,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'LumaLex',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
            ),
          ),
          IconButton(
            tooltip: _showReaderTextControls ? '收起字号调整' : '调整字号',
            onPressed: hasArticle ? _toggleReaderTextControls : null,
            icon: Text(
              'Aa',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: _showReaderTextControls
                        ? colors.primary
                        : hasArticle
                            ? colors.onSurfaceVariant
                            : colors.onSurface.withValues(alpha: 0.38),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          IconButton(
            tooltip: favorite ? '取消收藏' : '收藏单词',
            onPressed: hasArticle
                ? () => _toggleFavorite(_queryController.text)
                : null,
            icon: Icon(
              favorite ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 21,
              color: favorite ? const Color(0xFFF2A51A) : null,
            ),
          ),
          IconButton(
            tooltip: '最大化或恢复窗口',
            onPressed: () {
              unawaited(AndroidProcessTextWindow.toggleMaximized());
            },
            icon: const Icon(Icons.open_in_full_rounded, size: 19),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget _buildProcessTextResizeHandle() => Semantics(
        label: '调整查词窗口尺寸',
        hint: '拖动以改变宽度和高度',
        child: const SizedBox.square(
          dimension: 42,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.all(7),
              child: Icon(Icons.drag_handle_rounded, size: 22),
            ),
          ),
        ),
      );

  PreferredSizeWidget _buildCompactAppBar({required bool shortMobile}) =>
      AppBar(
        toolbarHeight: shortMobile ? 52 : 56,
        titleSpacing: 16,
        title: Text(
          switch (_destination) {
            _AppDestination.lookup => 'LumaLex',
            _AppDestination.wordbook => '词汇本',
            _AppDestination.dictionaries => '词典',
          },
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (shortMobile && _destination == _AppDestination.wordbook)
            IconButton(
              tooltip: '管理历史',
              onPressed: _showWordRecords,
              icon: const Icon(Icons.history_rounded),
            ),
          if (shortMobile && _destination == _AppDestination.dictionaries)
            if (_supportsDictionaryGroups) ...[
              IconButton(
                tooltip: '新建分组',
                onPressed: _showCreateDictionaryGroup,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              if (Platform.isIOS)
                _buildIosDictionaryImportMenu()
              else
                IconButton(
                  tooltip: '导入词典',
                  onPressed: _isImporting ? null : _pickAndImport,
                  icon: const Icon(Icons.add_rounded),
                ),
            ] else if (Platform.isIOS)
              _buildIosDictionaryImportMenu()
            else
              IconButton(
                tooltip: '导入词典',
                onPressed: _isImporting ? null : _pickAndImport,
                icon: const Icon(Icons.add_rounded),
              ),
          if (Platform.isAndroid &&
              _destination == _AppDestination.dictionaries)
            IconButton(
              tooltip: '关于与诊断',
              onPressed: _showAppDiagnostics,
              icon: const Icon(Icons.info_outline_rounded),
            ),
          if (isLumaLexDesktop)
            IconButton(
              key: const ValueKey('compact-settings-button'),
              tooltip: '设置',
              onPressed: _showSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          if (shortMobile) const SizedBox(width: 4),
        ],
      );

  Widget _buildIosDictionaryImportMenu() => PopupMenuButton<String>(
        tooltip: '添加词典',
        enabled: !_isImporting,
        icon: const Icon(Icons.add_rounded),
        onSelected: (action) {
          if (action == 'scan') {
            unawaited(_pickAndImport());
          } else if (action == 'external') {
            unawaited(_pickExternalAndImport());
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'scan',
            child: Row(
              children: [
                Icon(Icons.refresh_rounded),
                SizedBox(width: 12),
                Text('扫描 LumaLex 文件夹'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'external',
            child: Row(
              children: [
                Icon(Icons.folder_open_rounded),
                SizedBox(width: 12),
                Text('从其他位置添加'),
              ],
            ),
          ),
        ],
      );

  Widget _buildRailBrand({required bool expanded}) {
    final icon = Container(
      width: expanded ? 48 : 42,
      height: expanded ? 48 : 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(expanded ? 15 : 13),
      ),
      child: Image.asset(
        'assets/branding/lumalex-icon-ui.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
    if (!expanded) return icon;
    // NavigationRail measures its leading widget with unconstrained width.
    // Give the expanded brand an explicit width before using Expanded for the
    // label so it remains visible and overflow-free in debug and release.
    return SizedBox(
      width: 212,
      child: Row(
        children: [
          icon,
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'LumaLex',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopDictionaryRail({
    required bool expanded,
    required double availableHeight,
  }) {
    final colors = Theme.of(context).colorScheme;
    final inlineListHeight = expanded ? availableHeight - 470 : 0.0;
    final showInlineList =
        expanded && availableHeight >= 700 && inlineListHeight >= 200;
    final entries = _availableEntries;
    final selected =
        entries.where((entry) => entry.mdxPath == _selectedMdxPath).firstOrNull;
    final position = dictionaryResultPositionLabel(
      entries.map((entry) => entry.mdxPath),
      _selectedMdxPath,
    );
    final desiredPopupHeight = 104.0 + entries.length * 50.0;
    final popupHeight = desiredPopupHeight.clamp(
      180.0,
      (availableHeight - 24).clamp(180.0, 640.0),
    );

    final launcher = Padding(
      padding:
          EdgeInsets.fromLTRB(expanded ? 16 : 10, 14, expanded ? 16 : 10, 0),
      child: MenuAnchor(
        key: _desktopDictionaryAnchorKey,
        controller: _desktopDictionaryMenuController,
        style: MenuStyle(
          alignment: AlignmentDirectional.topEnd,
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        onClose: () {
          _desktopDictionaryHoverTimer?.cancel();
          _desktopDictionaryExitTimer?.cancel();
          _desktopDictionaryMenuHeldOpen = false;
        },
        menuChildren: [
          MouseRegion(
            onEnter: (_) => _desktopDictionaryExitTimer?.cancel(),
            onExit: (_) => _scheduleDesktopDictionaryMenuClose(),
            child: SizedBox(
              width: 320,
              height: popupHeight,
              child: _buildDesktopDictionaryList(floating: true),
            ),
          ),
        ],
        builder: (context, controller, child) => MouseRegion(
          onEnter: (event) {
            if (!showInlineList && event.kind == PointerDeviceKind.mouse) {
              _scheduleDesktopDictionaryMenuOpen();
            }
          },
          onExit: (_) {
            _desktopDictionaryHoverTimer?.cancel();
            _scheduleDesktopDictionaryMenuClose();
          },
          child: expanded
              ? Tooltip(
                  message:
                      '切换查词词典${selected == null ? '' : '：${selected.title}'}',
                  child: Material(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      key: const ValueKey('desktop-dictionary-launcher'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: _toggleDesktopDictionaryMenu,
                      child: SizedBox(
                        width: 212,
                        height: 52,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Icon(Icons.view_list_rounded,
                                  size: 22, color: colors.primary),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(selected?.title ?? '查词词典',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                              ),
                              if (selected != null)
                                Text(position,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: colors.primary)),
                              const Icon(Icons.chevron_right_rounded, size: 19),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : Tooltip(
                  message:
                      '查词词典${selected == null ? '' : '：${selected.title}'}',
                  child: IconButton(
                    key: const ValueKey('desktop-dictionary-launcher'),
                    onPressed: _toggleDesktopDictionaryMenu,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(52),
                      backgroundColor: colors.surfaceContainerLow,
                    ),
                    icon: Icon(Icons.view_list_rounded,
                        size: 27, color: colors.primary),
                  ),
                ),
        ),
      ),
    );
    if (!showInlineList) return launcher;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        launcher,
        const SizedBox(height: 8),
        SizedBox(
          width: 212,
          height: inlineListHeight,
          child: _buildDesktopDictionaryList(floating: false),
        ),
      ],
    );
  }

  void _scheduleDesktopDictionaryMenuOpen() {
    _desktopDictionaryExitTimer?.cancel();
    _desktopDictionaryHoverTimer?.cancel();
    _desktopDictionaryHoverTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted &&
          _desktopDictionaryAnchorKey.currentContext != null &&
          !_desktopDictionaryMenuController.isOpen) {
        _desktopDictionaryMenuHeldOpen = false;
        _desktopDictionaryMenuController.open();
        _revealSelectedDesktopDictionary(
            _desktopDictionaryPopupScrollController);
      }
    });
  }

  void _scheduleDesktopDictionaryMenuClose() {
    if (_desktopDictionaryMenuHeldOpen) return;
    _desktopDictionaryExitTimer?.cancel();
    _desktopDictionaryExitTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted && !_desktopDictionaryMenuHeldOpen) {
        _desktopDictionaryMenuController.close();
      }
    });
  }

  void _toggleDesktopDictionaryMenu() {
    _desktopDictionaryHoverTimer?.cancel();
    _desktopDictionaryExitTimer?.cancel();
    if (_desktopDictionaryMenuController.isOpen) {
      if (_desktopDictionaryMenuHeldOpen) {
        _desktopDictionaryMenuController.close();
      } else {
        _desktopDictionaryMenuHeldOpen = true;
      }
    } else {
      _desktopDictionaryMenuHeldOpen = true;
      _desktopDictionaryMenuController.open();
      _revealSelectedDesktopDictionary(_desktopDictionaryPopupScrollController);
    }
  }

  void _revealSelectedDesktopDictionary(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final index = _availableEntries
          .indexWhere((entry) => entry.mdxPath == _selectedMdxPath);
      if (index < 0) return;
      final position = controller.position;
      final target = (index * 50.0 - position.viewportDimension / 2 + 25)
          .clamp(0.0, position.maxScrollExtent);
      if ((position.pixels - target).abs() > 50) {
        controller.jumpTo(target);
      }
    });
  }

  Widget _buildDesktopDictionaryList({required bool floating}) {
    final colors = Theme.of(context).colorScheme;
    final entries = _availableEntries;
    final scopeChoices = <({String id, String name})>[
      (id: DictionaryGroupScope.all, name: '全部'),
      for (final group in _dictionaryGroupSnapshot.groups)
        (id: group.id, name: group.name),
      (id: DictionaryGroupScope.ungrouped, name: '未分组'),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('词典结果',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  if (_supportsDictionaryGroups)
                    PopupMenuButton<String>(
                      tooltip: '选择查词分组',
                      onOpened: () {
                        _desktopDictionaryMenuHeldOpen = true;
                        _desktopDictionaryExitTimer?.cancel();
                      },
                      onCanceled: () {
                        _desktopDictionaryMenuHeldOpen = false;
                        _scheduleDesktopDictionaryMenuClose();
                      },
                      onSelected: (scopeId) {
                        _desktopDictionaryMenuController.close();
                        unawaited(_selectDictionaryScope(scopeId));
                      },
                      itemBuilder: (context) => [
                        for (final scope in scopeChoices)
                          PopupMenuItem(
                            value: scope.id,
                            child: Text(scope.name),
                          ),
                      ],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 106),
                            child: Text(
                              _dictionaryScopeName(_activeDictionaryScopeId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: colors.primary),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down_rounded, size: 20),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '当前分组没有可用词典',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: floating
                        ? _desktopDictionaryPopupScrollController
                        : _desktopDictionaryInlineScrollController,
                    key: PageStorageKey<String>(floating
                        ? 'desktop-dictionary-popup-list'
                        : 'desktop-dictionary-inline-list'),
                    itemExtent: 50,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final selected = entry.mdxPath == _selectedMdxPath;
                      final articles = _articlesByDictionary[entry.mdxPath];
                      final hasQuery = _queryController.text.trim().isNotEmpty;
                      final pending =
                          hasQuery && _isSearching && articles == null;
                      final found = articles?.isNotEmpty ?? false;
                      final status = !hasQuery
                          ? '尚未查词'
                          : pending
                              ? '正在查询'
                              : found
                                  ? '已找到词条'
                                  : '未收录该词';
                      return Tooltip(
                        message: '${entry.title} · $status',
                        child: Material(
                          color: selected
                              ? colors.primaryContainer.withValues(alpha: 0.72)
                              : Colors.transparent,
                          child: InkWell(
                            key: ValueKey('desktop-dictionary-$index'),
                            onTap: () {
                              _desktopDictionaryMenuController.close();
                              _selectDestination(_AppDestination.lookup);
                              _selectDictionaryResult(entry);
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Row(
                                children: [
                                  Icon(Icons.menu_book_rounded,
                                      size: 18,
                                      color: selected
                                          ? colors.primary
                                          : colors.outline),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(entry.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color:
                                                !pending && hasQuery && !found
                                                    ? colors.onSurfaceVariant
                                                    : null)),
                                  ),
                                  if (pending)
                                    const SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  else if (hasQuery && !found)
                                    Icon(Icons.remove_rounded,
                                        size: 16,
                                        color: colors.onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsNavigationButton({required bool expanded}) {
    final colors = Theme.of(context).colorScheme;
    final backgroundColor =
        _showSettingsPage ? colors.secondaryContainer : Colors.transparent;
    final foregroundColor = _showSettingsPage
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    if (!expanded) {
      return Tooltip(
        message: '设置',
        child: IconButton(
          key: const ValueKey('settings-navigation-button'),
          onPressed: _showSettings,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(52),
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
          ),
          icon: Icon(
            _showSettingsPage
                ? Icons.settings_rounded
                : Icons.settings_outlined,
            size: 29,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: 212,
        height: 52,
        child: TextButton.icon(
          key: const ValueKey('settings-navigation-button'),
          onPressed: _showSettings,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            shape: const StadiumBorder(),
          ),
          icon: Icon(
            _showSettingsPage
                ? Icons.settings_rounded
                : Icons.settings_outlined,
            size: 27,
          ),
          label: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text(
              '设置',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildSettingsAppBar() => AppBar(
        leading: IconButton(
          tooltip: '返回',
          onPressed: _closeSettings,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text(
          '设置',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      );

  Widget _buildSettingsPage() => AppSettingsPage(
        macosAccessibilityGranted: _macosAccessibilityGranted,
        onShowCurrentMacosApplication: () =>
            unawaited(_windowsScreenLookup.showCurrentApplication()),
        onOpenMacosAccessibilitySettings: () =>
            unawaited(_openMacosAccessibilitySettings()),
        onRefreshMacosAccessibilityPermission: () =>
            unawaited(_refreshMacosAccessibilityPermission()),
        closeBehavior: _windowsCloseBehavior,
        closeBehaviorSaving: _windowsCloseBehaviorSaving,
        onCloseBehaviorChanged: (behavior) {
          unawaited(_setWindowsCloseBehavior(behavior));
        },
        screenLookupEnabled: _windowsScreenLookupEnabled,
        screenLookupSaving: _windowsScreenLookupSaving,
        screenLookupShortcut: _windowsScreenLookupShortcut,
        onScreenLookupEnabledChanged: (enabled) {
          unawaited(_setWindowsScreenLookupEnabled(enabled));
        },
        onScreenLookupShortcutChanged: (shortcut) {
          unawaited(_setWindowsScreenLookupShortcut(shortcut));
        },
        screenLookupAiEnabled: _windowsScreenLookupAiEnabled,
        screenLookupAiSaving: _windowsScreenLookupAiSaving,
        screenLookupAiKeyStored: _windowsScreenLookupAiKeyStored,
        screenLookupAiBaseUrlController: _screenLookupAiBaseUrlController,
        screenLookupAiModelController: _screenLookupAiModelController,
        screenLookupAiApiKeyController: _screenLookupAiApiKeyController,
        onScreenLookupAiEnabledChanged: (enabled) {
          unawaited(_setWindowsScreenLookupAiEnabled(enabled));
        },
        onSaveScreenLookupAiSettings: () {
          unawaited(_saveWindowsScreenLookupAiSettings());
        },
        onTestScreenLookupAiSettings: () {
          unawaited(_testWindowsScreenLookupAiSettings());
        },
        onDeleteScreenLookupAiApiKey: () {
          unawaited(_deleteWindowsScreenLookupAiApiKey());
        },
        textScale: _textScale,
        onTextScaleChanged: _setCurrentTextScale,
        onExportLearningData: () => unawaited(_exportLearningData()),
        onImportLearningData: () => unawaited(_importLearningData()),
        onSaveDiagnostics: () => unawaited(_saveWindowsDiagnosticsReport()),
      );

  /// Keeps each navigation destination mounted while another tab is visible.
  ///
  /// In particular, the lookup destination owns a WebView. Rebuilding it on
  /// every tab switch makes the current article reload and loses its native
  /// rendering state. [IndexedStack] changes only which child is painted,
  /// while preserving all three page states and their scroll positions.
  Widget _buildDestinationPages({
    required bool compact,
    required bool shortMobile,
  }) =>
      IndexedStack(
        index: _destination.index,
        children: [
          KeyedSubtree(
            key: const PageStorageKey<String>('lookup-destination'),
            child: _buildLookupPage(compact: compact),
          ),
          KeyedSubtree(
            key: const PageStorageKey<String>('wordbook-destination'),
            child: _buildWordbookPage(
              compact: compact,
              shortMobile: shortMobile,
            ),
          ),
          KeyedSubtree(
            key: const PageStorageKey<String>('dictionaries-destination'),
            child: _buildDictionariesPage(
              compact: compact,
              shortMobile: shortMobile,
            ),
          ),
        ],
      );

  Widget _buildLookupPage({required bool compact}) {
    final readerOpen = _hasVisibleReaderArticle;
    return SafeArea(
      // The mobile lookup header is responsible for its own safe-area inset
      // because the generic AppBar is intentionally absent on this page.
      top: compact,
      bottom: compact && readerOpen,
      child: Center(
        child: ConstrainedBox(
          // A maximized desktop window should use the available reading area.
          // Keep a generous ceiling for ultra-wide displays while preserving
          // the established tablet/mobile measure on other platforms.
          constraints: BoxConstraints(
            maxWidth: isLumaLexDesktop ? 2400 : 1280,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.processTextMode ? 10 : (compact ? 12 : 24),
              widget.processTextMode ? 6 : (compact ? 8 : 18),
              widget.processTextMode ? 10 : (compact ? 12 : 24),
              widget.processTextMode ? 6 : (compact ? 8 : 20),
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    if (widget.processTextMode)
                      if (_showReaderTextControls && readerOpen)
                        _buildProcessTextScaleControls()
                      else
                        _buildProcessTextSearchNavigation()
                    else
                      _buildLookupHeader(
                        readerOpen: readerOpen,
                        showSettingsAction: compact && isLumaLexDesktop,
                      ),
                    if (!widget.processTextMode &&
                        readerOpen &&
                        (_lookupNavigation.canGoBack ||
                            _lookupNavigation.canGoForward)) ...[
                      const SizedBox(height: 4),
                      _buildArticleNavigationControls(),
                    ],
                    if (!(isLumaLexDesktop &&
                            !compact &&
                            !widget.processTextMode) &&
                        _allAvailableEntries.isNotEmpty &&
                        _queryController.text.trim().isNotEmpty) ...[
                      SizedBox(height: widget.processTextMode ? 4 : 6),
                      _buildDictionaryScopeSelector(compact: compact),
                    ],
                    if (_lookupCorrection case final correction?) ...[
                      const SizedBox(height: 6),
                      _buildCorrectionBanner(correction),
                    ],
                    SizedBox(height: widget.processTextMode ? 4 : 8),
                    Expanded(child: _buildBody(compact: compact)),
                  ],
                ),
                if (_suggestions.isNotEmpty)
                  Positioned(
                    top: widget.processTextMode ? 48 : 64,
                    left: 0,
                    right: 0,
                    child: _buildSuggestions(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLookupHeader({
    required bool readerOpen,
    required bool showSettingsAction,
  }) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final useIconOnlyHomeButton = constraints.maxWidth < 520;
          return Row(
            children: [
              if (readerOpen && !widget.processTextMode) ...[
                LookupHomeButton(
                  iconOnly: useIconOnlyHomeButton,
                  onPressed: _isSearching ? null : _clearLookup,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(child: _buildSearchField()),
              if (readerOpen) ...[
                const SizedBox(width: 4),
                ReaderTextScaleToggleButton(
                  key: const ValueKey('reader-text-scale-toggle'),
                  expanded: _showReaderTextControls,
                  onPressed: _toggleReaderTextControls,
                ),
              ],
              if (showSettingsAction) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('compact-settings-button'),
                  tooltip: '设置',
                  onPressed: _showSettings,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(44),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ],
          );
        },
      );

  Widget _buildProcessTextSearchNavigation() => SizedBox(
        height: 44,
        child: Row(
          key: const ValueKey('process-text-search-navigation'),
          children: [
            if (_lookupNavigation.canGoBack)
              _buildProcessTextNavigationButton(
                tooltip: '上一个词条',
                icon: Icons.chevron_left_rounded,
                onPressed: _isSearching ? null : () => unawaited(_goBack()),
              ),
            Expanded(child: _buildSearchField(processTextCompact: true)),
            if (_lookupNavigation.canGoForward)
              _buildProcessTextNavigationButton(
                tooltip: '下一个词条',
                icon: Icons.chevron_right_rounded,
                onPressed: _isSearching ? null : () => unawaited(_goForward()),
              ),
          ],
        ),
      );

  Widget _buildProcessTextNavigationButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) =>
      SizedBox.square(
        dimension: 40,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(icon, size: 22),
        ),
      );

  Widget _buildProcessTextScaleControls() {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Material(
        key: const ValueKey('process-text-scale-controls'),
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            _buildProcessTextNavigationButton(
              tooltip: '缩小字号',
              icon: Icons.remove_rounded,
              onPressed: _currentTextScale <= 0.6
                  ? null
                  : () => _setCurrentTextScale(_currentTextScale - 0.1),
            ),
            Expanded(
              child: Text(
                '字号 ${(_currentTextScale * 100).round()}%',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            _buildProcessTextNavigationButton(
              tooltip: '放大字号',
              icon: Icons.add_rounded,
              onPressed: _currentTextScale >= 2
                  ? null
                  : () => _setCurrentTextScale(_currentTextScale + 0.1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArticleNavigationControls() => Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          children: [
            if (_lookupNavigation.canGoBack)
              OutlinedButton.icon(
                onPressed: _isSearching ? null : () => unawaited(_goBack()),
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('上一个词条'),
              ),
            if (_lookupNavigation.canGoForward)
              OutlinedButton.icon(
                onPressed: _isSearching ? null : () => unawaited(_goForward()),
                icon: const Icon(Icons.redo_rounded, size: 18),
                label: const Text('下一个词条'),
              ),
          ],
        ),
      );

  Widget _buildWordbookPage({
    required bool compact,
    required bool shortMobile,
  }) =>
      Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: destinationPageMaxWidthForOperatingSystem(
              Platform.operatingSystem,
              fallback: 920,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 28,
              shortMobile ? 4 : (compact ? 12 : 24),
              compact ? 16 : 28,
              shortMobile ? 6 : (compact ? 12 : 20),
            ),
            child: DefaultTabController(
              length: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!shortMobile) ...[
                    Row(
                      children: [
                        if (!compact)
                          Expanded(
                            child: Text(
                              '词汇本',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          )
                        else
                          const Spacer(),
                        TextButton.icon(
                          onPressed: _showWordRecords,
                          icon: const Icon(Icons.history_rounded, size: 18),
                          label: const Text('管理历史'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '收藏词汇会保存在这里，并自动加入闪卡复习计划。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TabBar(
                    tabs: shortMobile
                        ? const [
                            Tab(text: '收藏'),
                            Tab(text: '复习'),
                          ]
                        : const [
                            Tab(
                              icon: Icon(Icons.star_outline),
                              text: '收藏',
                            ),
                            Tab(
                              icon: Icon(Icons.style_outlined),
                              text: '复习',
                            ),
                          ],
                  ),
                  SizedBox(height: shortMobile ? 4 : 8),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildFavoriteWordbook(),
                        _buildReviewPlaceholder(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildFavoriteWordbook() {
    final colors = Theme.of(context).colorScheme;
    if (_favorites.isEmpty) {
      return _buildSectionEmptyState(
        icon: Icons.star_outline_rounded,
        title: '还没有收藏词汇',
        message: '在查词结果页点击星标，即可把单词加入词汇本。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: _favorites.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Text('共 ${_favorites.length} 个收藏'),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    if (await _confirmClearWordList(
                      context,
                      title: '清空全部收藏？',
                      message: '全部收藏单词将被删除，此操作无法撤销。',
                    )) {
                      await _removeFavoriteWords(_favorites);
                    }
                  },
                  child: const Text('清空'),
                ),
              ],
            ),
          );
        }
        final word = _favorites[index - 1];
        return ListTile(
          leading: Icon(Icons.star_rounded, color: colors.tertiary),
          title:
              Text(word, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('点击查看词条'),
          trailing: IconButton(
            tooltip: '从收藏中删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _removeFavoriteWords([word]),
          ),
          onTap: () => unawaited(_openWordInLookup(word)),
        );
      },
    );
  }

  Widget _buildReviewPlaceholder() {
    if (_favorites.isEmpty) {
      return _buildSectionEmptyState(
        icon: Icons.style_outlined,
        title: '还没有可复习的词汇',
        message: '先在查词结果页收藏单词，它们会自动加入今天的复习队列。',
      );
    }

    final now = DateTime.now();
    final dueCards = dueReviewCards(_reviewCards, now: now);
    if (dueCards.isEmpty) {
      final nextCard = List<ReviewCard>.of(_reviewCards)
        ..sort((left, right) => left.dueAt.compareTo(right.dueAt));
      final nextDue =
          nextCard.isEmpty ? null : _reviewDueLabel(nextCard.first.dueAt, now);
      return _buildSectionEmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: '今天的复习完成了',
        message: nextDue == null ? '继续收藏需要学习的词汇吧。' : '下次复习：$nextDue。',
      );
    }

    final card = dueCards.first;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.style_rounded, color: colors.primary),
                    const SizedBox(width: 8),
                    Text(
                      '待复习 ${dueCards.length} 张',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      '已收藏 ${_favorites.length} 个',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Material(
                  color: _reviewAnswerVisible
                      ? colors.surfaceContainerLow
                      : colors.primaryContainer.withValues(alpha: 0.48),
                  elevation: 1,
                  shadowColor: const Color(0x1A000000),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      if (!_reviewAnswerVisible) {
                        setState(() => _reviewAnswerVisible = true);
                      }
                    },
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _reviewAnswerVisible ? '词典摘要' : '词汇卡',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 18),
                            SelectableText(
                              card.word,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.5,
                                  ),
                            ),
                            if (!_reviewAnswerVisible) ...[
                              const SizedBox(height: 28),
                              Text(
                                '先回想释义，再轻触卡片显示答案。',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    setState(() => _reviewAnswerVisible = true),
                                icon: const Icon(Icons.visibility_rounded),
                                label: const Text('显示释义'),
                              ),
                            ] else ...[
                              const SizedBox(height: 22),
                              Divider(color: colors.outlineVariant),
                              const SizedBox(height: 14),
                              Text(
                                card.gloss ?? '这个收藏来自旧版本，尚未保存词典摘要。可打开完整词条查看释义。',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(height: 1.55),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () =>
                                      unawaited(_openWordInLookup(card.word)),
                                  icon: const Icon(Icons.search_rounded),
                                  label: const Text('打开完整词条'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_reviewAnswerVisible) ...[
                  const SizedBox(height: 16),
                  Text(
                    '这张词记得如何？',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildReviewRatingButton(
                        card,
                        ReviewRating.again,
                        label: '再来一次',
                        detail: '10 分钟',
                      ),
                      _buildReviewRatingButton(
                        card,
                        ReviewRating.hard,
                        label: '有点模糊',
                        detail: '1 天',
                      ),
                      _buildReviewRatingButton(
                        card,
                        ReviewRating.good,
                        label: '认识',
                        detail: _reviewIntervalLabel(card, ReviewRating.good),
                        emphasized: true,
                      ),
                      _buildReviewRatingButton(
                        card,
                        ReviewRating.easy,
                        label: '很熟',
                        detail: _reviewIntervalLabel(card, ReviewRating.easy),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReviewRatingButton(
    ReviewCard card,
    ReviewRating rating, {
    required String label,
    required String detail,
    bool emphasized = false,
  }) =>
      emphasized
          ? FilledButton(
              onPressed: () => _rateReviewCard(card, rating),
              child: _reviewRatingLabel(label, detail),
            )
          : OutlinedButton(
              onPressed: () => _rateReviewCard(card, rating),
              child: _reviewRatingLabel(label, detail),
            );

  Widget _reviewRatingLabel(String label, String detail) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          Text(
            detail,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      );

  String _reviewIntervalLabel(ReviewCard card, ReviewRating rating) {
    final scheduled = scheduleReview(card, rating, now: DateTime.now());
    return '${scheduled.intervalDays} 天';
  }

  String _reviewDueLabel(DateTime dueAt, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
    final difference = dueDay.difference(today).inDays;
    if (difference == 0) return '今天';
    if (difference == 1) return '明天';
    return '$difference 天后';
  }

  Future<void> _rateReviewCard(
    ReviewCard card,
    ReviewRating rating,
  ) async {
    final scheduled = scheduleReview(card, rating, now: DateTime.now());
    final updated = _reviewCards
        .map(
          (candidate) => candidate.word.toLowerCase() == card.word.toLowerCase()
              ? scheduled
              : candidate,
        )
        .toList(growable: false);
    _wordRecordsMutationGeneration++;
    setState(() {
      _reviewCards = updated;
      _reviewAnswerVisible = false;
    });
    try {
      await widget.wordRecords.saveReviewCards(updated);
    } catch (_) {
      if (mounted) {
        _showMessage('复习进度已更新，但暂时无法保存。');
      }
    }
  }

  Widget _buildDictionariesPage({
    required bool compact,
    required bool shortMobile,
  }) {
    if (_isLibraryLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: destinationPageMaxWidthForOperatingSystem(
            Platform.operatingSystem,
            fallback: 980,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 28,
            shortMobile ? 4 : (compact ? 12 : 24),
            compact ? 16 : 28,
            shortMobile ? 6 : (compact ? 12 : 20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!shortMobile) ...[
                Row(
                  children: [
                    if (!compact)
                      Expanded(
                        child: Text(
                          '词典',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (_supportsDictionaryGroups) ...[
                      OutlinedButton.icon(
                        onPressed: _showCreateDictionaryGroup,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('新建分组'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (Platform.isIOS) ...[
                      OutlinedButton.icon(
                        onPressed: _isImporting ? null : _pickExternalAndImport,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('其他位置'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _isImporting ? null : _pickAndImport,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('扫描文件夹'),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: _isImporting ? null : _pickAndImport,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('导入'),
                      ),
                    if (Platform.isAndroid && !compact) ...[
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        tooltip: '关于与诊断',
                        onPressed: _showAppDiagnostics,
                        icon: const Icon(Icons.info_outline_rounded),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  Platform.isIOS
                      ? '默认目录：${IosDictionaryHome.displayPath}。启用的词典会参与查词。'
                      : '管理本地 MDX/MDD 文件，启用的词典会参与查词。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
              ],
              Expanded(
                child: _libraryEntries.isEmpty
                    ? _buildSectionEmptyState(
                        icon: Icons.library_add_outlined,
                        title:
                            Platform.isIOS ? '把词典放入 LumaLex 文件夹' : '建立你的本地词典库',
                        message: Platform.isIOS
                            ? '在“文件”App 中打开 ${IosDictionaryHome.displayPath}，放入包含 MDX 与 MDD 的词典文件夹。'
                            : '导入一个包含 MDX 与 MDD 文件的文件夹后，即可离线查词。',
                        actionLabel: Platform.isIOS ? '扫描词典文件夹' : '导入词典',
                        actionIcon:
                            Platform.isIOS ? Icons.refresh_rounded : null,
                        onAction: _isImporting ? null : _pickAndImport,
                        secondaryActionLabel: Platform.isIOS ? '从其他位置添加' : null,
                        onSecondaryAction: Platform.isIOS && !_isImporting
                            ? _pickExternalAndImport
                            : null,
                      )
                    : _supportsDictionaryGroups
                        ? _buildGroupedDictionaryLibrary()
                        : _buildDictionaryLibraryList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDictionaryLibraryList() => ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        buildDefaultDragHandles: false,
        itemCount: _libraryEntries.length,
        itemBuilder: (context, index) {
          final entry = _libraryEntries[index];
          final isAvailable = _availableMdxPaths.contains(entry.mdxPath);
          return Card(
            key: ValueKey(entry.mdxPath),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(entry.title),
              subtitle: Text(
                !entry.isEnabled
                    ? '已停用'
                    : isAvailable
                        ? '参与查询'
                        : _failedMdxPaths.contains(entry.mdxPath)
                            ? '文件暂时无法访问'
                            : '正在后台准备',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: entry.isEnabled,
                    onChanged: _isImporting
                        ? null
                        : (enabled) => _setDictionaryEnabled(entry, enabled),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多词典操作',
                    onSelected: (action) async {
                      if (action == 'rename') {
                        await _renameDictionary(context, entry);
                      } else if (action == 'remove') {
                        await _remove(entry);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('修改显示名称')),
                      PopupMenuItem(value: 'remove', child: Text('从词典库移除')),
                    ],
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.drag_handle_rounded),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        onReorderItem: _reorderDictionaryLibrary,
      );

  Widget _buildGroupedDictionaryLibrary() {
    final groups = _dictionaryGroupSnapshot.groups;
    return CustomScrollView(
      slivers: [
        for (final group in groups)
          ..._buildDictionaryGroupSlivers(
            groupId: group.id,
            title: group.name,
            group: group,
          ),
        ..._buildDictionaryGroupSlivers(
          groupId: DictionaryGroupScope.ungrouped,
          title: '未分组',
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  List<Widget> _buildDictionaryGroupSlivers({
    required String groupId,
    required String title,
    DictionaryGroup? group,
  }) {
    final entries = dictionaryEntriesForScope(_libraryEntries, groupId);
    final queryableCount = entries
        .where(
          (entry) =>
              entry.isEnabled && _availableMdxPaths.contains(entry.mdxPath),
        )
        .length;
    final expanded = _expandedDictionaryGroupIds.contains(groupId);
    final groupColor = group == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : _dictionaryGroupColor(group);
    return [
      SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedDictionaryGroupIds.remove(groupId);
                } else {
                  _expandedDictionaryGroupIds.add(groupId);
                }
              });
            },
            leading: Icon(
              group == null ? Icons.inbox_outlined : Icons.folder_rounded,
              color: groupColor,
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('$queryableCount 本可查询 · 共 ${entries.length} 本'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                if (group != null)
                  PopupMenuButton<String>(
                    tooltip: '更多分组操作',
                    onSelected: (action) {
                      if (action == 'rename') {
                        unawaited(_renameDictionaryGroup(group));
                      } else if (action == 'color') {
                        unawaited(_changeDictionaryGroupColor(group));
                      } else if (action == 'delete') {
                        unawaited(_deleteDictionaryGroup(group));
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text('重命名分组'),
                      ),
                      PopupMenuItem(value: 'color', child: Text('更改文件夹颜色')),
                      PopupMenuItem(value: 'delete', child: Text('删除分组')),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
      if (expanded && entries.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Text(
              '此分组暂无词典。可从其他分组的词典菜单中移动到这里。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ),
      if (expanded && entries.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.only(top: 8),
          sliver: SliverReorderableList(
            key: ValueKey('dictionary-reorder-$groupId'),
            itemCount: entries.length,
            itemBuilder: (context, index) => _buildGroupedDictionaryTile(
              entries[index],
              index,
              entries,
            ),
            onReorderItem: (oldIndex, newIndex) =>
                _reorderDictionaryGroup(entries, oldIndex, newIndex),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 10)),
    ];
  }

  Widget _buildGroupedDictionaryTile(
    DictionaryLibraryEntry entry,
    int index,
    List<DictionaryLibraryEntry> groupEntries,
  ) {
    final isAvailable = _availableMdxPaths.contains(entry.mdxPath);
    return Card(
      key: ValueKey('grouped-${entry.mdxPath}'),
      margin: const EdgeInsets.only(bottom: 7),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 5, 4, 5),
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          !entry.isEnabled
              ? '已停用'
              : isAvailable
                  ? '参与查询'
                  : _failedMdxPaths.contains(entry.mdxPath)
                      ? '文件暂时无法访问'
                      : '正在后台准备',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: entry.isEnabled,
              onChanged: _isImporting
                  ? null
                  : (enabled) => _setDictionaryEnabled(entry, enabled),
            ),
            PopupMenuButton<String>(
              tooltip: '更多词典操作',
              onSelected: (action) async {
                if (action == 'rename') {
                  await _renameDictionary(context, entry);
                } else if (action == 'move') {
                  await _showMoveDictionaryToGroup(entry);
                } else if (action == 'up' && index > 0) {
                  await _reorderDictionaryGroup(
                    groupEntries,
                    index,
                    index - 1,
                  );
                } else if (action == 'down' &&
                    index < groupEntries.length - 1) {
                  await _reorderDictionaryGroup(
                    groupEntries,
                    index,
                    index + 1,
                  );
                } else if (action == 'remove') {
                  await _remove(entry);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('修改显示名称'),
                ),
                const PopupMenuItem(value: 'move', child: Text('移动到分组')),
                if (index > 0)
                  const PopupMenuItem(value: 'up', child: Text('上移')),
                if (index < groupEntries.length - 1)
                  const PopupMenuItem(value: 'down', child: Text('下移')),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('从词典库移除'),
                ),
              ],
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.drag_handle_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reorderDictionaryGroup(
    List<DictionaryLibraryEntry> groupEntries,
    int oldIndex,
    int newIndex,
  ) async {
    final previousLibrary = List<DictionaryLibraryEntry>.of(_libraryEntries);
    final reorderedGroup = List<DictionaryLibraryEntry>.of(groupEntries);
    final moved = reorderedGroup.removeAt(oldIndex);
    reorderedGroup.insert(newIndex, moved);
    final groupPaths = groupEntries.map((entry) => entry.mdxPath).toSet();
    var replacementIndex = 0;
    final reorderedLibrary = _libraryEntries.map((entry) {
      if (!groupPaths.contains(entry.mdxPath)) return entry;
      return reorderedGroup[replacementIndex++];
    }).toList(growable: false);
    setState(() => _libraryEntries = reorderedLibrary);
    try {
      final saved = await widget.library.reorder(
        reorderedLibrary.map((entry) => entry.mdxPath).toList(growable: false),
      );
      if (mounted) setState(() => _libraryEntries = saved);
    } catch (_) {
      if (mounted) {
        setState(() => _libraryEntries = previousLibrary);
        _showMessage('无法保存词典顺序。');
      }
    }
  }

  Widget _buildSectionEmptyState({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    IconData? actionIcon,
    VoidCallback? onAction,
    String? secondaryActionLabel,
    VoidCallback? onSecondaryAction,
  }) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 42, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: onAction,
                    icon: Icon(actionIcon ?? Icons.add_rounded),
                    label: Text(actionLabel),
                  ),
                ],
                if (secondaryActionLabel != null &&
                    onSecondaryAction != null) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onSecondaryAction,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(secondaryActionLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Future<void> _openWordInLookup(String word) async {
    _selectDestination(_AppDestination.lookup);
    _queryController.value = TextEditingValue(
      text: word,
      selection: TextSelection.collapsed(offset: word.length),
    );
    await _startNewLookup(word);
  }

  Future<void> _reorderDictionaryLibrary(int oldIndex, int newIndex) async {
    final reordered = List.of(_libraryEntries);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    setState(() => _libraryEntries = reordered);
    try {
      final saved = await widget.library.reorder(
        reordered.map((entry) => entry.mdxPath).toList(growable: false),
      );
      if (mounted) setState(() => _libraryEntries = saved);
    } catch (_) {
      if (mounted) _showMessage('无法保存词典顺序。');
    }
  }

  Widget _buildSearchField({bool processTextCompact = false}) {
    final colors = Theme.of(context).colorScheme;
    final hasText = _queryController.text.isNotEmpty;
    return SearchBar(
      controller: _queryController,
      focusNode: _searchFocusNode,
      hintText: '搜索单词、短语或词条',
      leading: Padding(
        padding: EdgeInsets.only(left: processTextCompact ? 0 : 4),
        child: Icon(
          Icons.search_rounded,
          color: colors.primary,
          size: processTextCompact ? 21 : 25,
        ),
      ),
      trailing: [
        if (_isSearching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: colors.primary,
              ),
            ),
          )
        else if (hasText)
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.close_rounded, size: 20),
            constraints: processTextCompact
                ? const BoxConstraints.tightFor(width: 40, height: 40)
                : null,
            padding: processTextCompact ? EdgeInsets.zero : null,
            onPressed: () {
              _queryController.clear();
              _suggest('');
              _lookup('');
              setState(() {});
            },
          ),
      ],
      constraints: BoxConstraints(
        minHeight: processTextCompact ? 44 : 58,
        maxHeight: processTextCompact ? 44 : 58,
      ),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: processTextCompact ? 10 : 16),
      ),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: const WidgetStatePropertyAll(Color(0xFFFFFFFF)),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStatePropertyAll(
        BorderSide(color: colors.outlineVariant),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(processTextCompact ? 14 : 18),
        ),
      ),
      textStyle: WidgetStatePropertyAll(
        (processTextCompact
                ? Theme.of(context).textTheme.bodyLarge
                : Theme.of(context).textTheme.titleMedium)
            ?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      hintStyle: WidgetStatePropertyAll(
        (processTextCompact
                ? Theme.of(context).textTheme.bodyLarge
                : Theme.of(context).textTheme.titleMedium)
            ?.copyWith(
          color: colors.onSurfaceVariant.withValues(alpha: 0.72),
          fontWeight: FontWeight.w400,
        ),
      ),
      onSubmitted: _startNewLookup,
      onChanged: (value) {
        _lookupCorrectionTimer?.cancel();
        _lookupCorrectionTimer = null;
        setState(() => _lookupCorrection = null);
        _suggest(value);
      },
    );
  }

  Widget _buildSuggestions() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxHeight: 224),
      margin: const EdgeInsets.only(top: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x140E3538),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 48),
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          return ListTile(
            dense: true,
            selected: index == _selectedSuggestionIndex,
            selectedTileColor: colors.primaryContainer.withValues(alpha: 0.45),
            leading: Icon(
              Icons.manage_search_rounded,
              size: 20,
              color: colors.primary,
            ),
            title: Text(
              suggestion,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            trailing: Icon(
              Icons.north_west_rounded,
              size: 17,
              color: colors.outline,
            ),
            onTap: () => _activateSuggestion(suggestion),
          );
        },
      ),
    );
  }

  Widget _buildBody({required bool compact}) {
    if (_isLibraryLoading) {
      return _buildEmptyState(
        icon: Icons.auto_stories_rounded,
        title: '正在打开词典库',
        message: '词典索引准备完成后即可开始查词。',
        loading: true,
      );
    }
    if (_availableEntries.isEmpty) {
      final hasAccessibleDictionary = _libraryEntries.any(
        (entry) => _availableMdxPaths.contains(entry.mdxPath),
      );
      return _buildEmptyState(
        icon: _libraryEntries.isEmpty
            ? Icons.library_add_rounded
            : Icons.library_books_rounded,
        title: _libraryEntries.isEmpty ? '建立你的离线词典库' : '当前没有可用词典',
        message: _libraryEntries.isEmpty
            ? Platform.isIOS
                ? '将 MDX/MDD 词典放入 ${IosDictionaryHome.displayPath}，然后扫描导入。'
                : '导入 MDX 与 MDD 词典，所有内容都保留在本地。'
            : hasAccessibleDictionary
                ? '请在词典库中启用至少一本参与查询的词典。'
                : '词典文件暂时无法访问，请打开词典库恢复访问。',
        actionLabel: _libraryEntries.isEmpty
            ? Platform.isIOS
                ? '扫描词典文件夹'
                : '导入第一本词典'
            : '打开词典库',
        onAction: _libraryEntries.isEmpty ? _pickAndImport : _showLibrary,
      );
    }
    if (_queryController.text.trim().isEmpty) {
      if (_history.isNotEmpty) {
        return _buildRecentSearches();
      }
      return _buildEmptyState(
        icon: Icons.travel_explore_rounded,
        title: '想查哪个词？',
        message: '在上方输入单词或短语，LumaLex 会同时检索已启用的词典。',
      );
    }
    final selectedPath = _selectedMdxPath;
    if (selectedPath == null) {
      return _buildEmptyState(
        icon: Icons.menu_book_rounded,
        title: '没有可显示的内容',
        message: '请尝试切换词典或重新查询。',
      );
    }
    final entries = _availableEntries;
    return _buildAllDictionariesView(entries, compact: compact);
  }

  Widget _buildRecentSearches() {
    final colors = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.only(top: 2, bottom: 20),
      itemCount: _history.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 4, 8),
            child: Row(
              children: [
                Icon(Icons.history_rounded, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  '最近搜索',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    if (await _confirmClearWordList(
                      context,
                      title: '清空查词历史？',
                      message: '全部历史记录将被删除，此操作无法撤销。',
                    )) {
                      await _removeHistoryWords(_history);
                    }
                  },
                  child: const Text('清空'),
                ),
              ],
            ),
          );
        }
        final word = _history[index - 1];
        return ListTile(
          leading: const Icon(Icons.history_rounded),
          title:
              Text(word, style: const TextStyle(fontWeight: FontWeight.w500)),
          trailing: IconButton(
            tooltip: '删除这条历史',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => _removeHistoryWords([word]),
          ),
          onTap: () => unawaited(_openWordInLookup(word)),
        );
      },
    );
  }

  Widget _buildCorrectionBanner(
    ({String original, String replacement}) correction,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.secondary.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(Icons.spellcheck_rounded, size: 19, color: colors.secondary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '未找到“${correction.original}”，已显示“${correction.replacement}”。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllDictionariesView(
    List<DictionaryLibraryEntry> entries, {
    required bool compact,
  }) {
    final selected = entries
            .where((entry) => entry.mdxPath == _selectedMdxPath)
            .firstOrNull ??
        entries.first;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_readerPlatformPolicy.showWideDictionaryJumpRail &&
            constraints.maxWidth >= 980) {
          final articleView = _buildDictionaryArticleView(
            entries,
            selected,
            compact: false,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: articleView),
              const SizedBox(width: 14),
              SizedBox(
                width: 248,
                child: _buildDictionaryJumpRail(entries),
              ),
            ],
          );
        }
        // Small screens deliberately show one document at a time. The
        // dictionary selector lives above the reader and opens a sheet, which
        // avoids reserving a whole horizontal row for every installed title.
        return _buildDictionaryArticleView(
          entries,
          selected,
          compact: compact,
        );
      },
    );
  }

  Widget _buildDictionaryArticleView(
    List<DictionaryLibraryEntry> entries,
    DictionaryLibraryEntry selected, {
    required bool compact,
  }) {
    if (_readerPlatformPolicy.aggregateDictionaryResults) {
      if (_isSearching) {
        return _buildEmptyState(
          icon: Icons.hourglass_top_rounded,
          title: '正在准备全部词典内容',
          message: '完成后可在词典之间即时切换。',
          loading: true,
        );
      }
      final sections = <AggregateArticleSection>[
        for (final entry in entries)
          if (_articlesByDictionary[entry.mdxPath]?.firstOrNull
              case final article?)
            AggregateArticleSection(
              title: entry.title,
              article: article,
              textScale: _textScale,
            ),
      ];
      if (sections.isNotEmpty &&
          (_articlesByDictionary[selected.mdxPath]?.isNotEmpty ?? false)) {
        return _buildAndroidAggregateDictionaryReader(
          entries,
          sections,
          selected,
          compact: compact,
        );
      }
    }
    return _buildRetainedDictionaryReaders(
      entries,
      selected,
      compact: compact,
    );
  }

  Widget _buildAndroidAggregateDictionaryReader(
    List<DictionaryLibraryEntry> entries,
    List<AggregateArticleSection> sections,
    DictionaryLibraryEntry selected, {
    required bool compact,
  }) {
    final reader = AggregateArticlePage(
      key: ValueKey('android-aggregate-reader-$_readerQuery'),
      sections: sections,
      engine: widget.engine,
      controller: _aggregateArticleController,
      presentation: AggregateArticlePresentation.selectedDictionary,
      initialMdxPath: selected.mdxPath,
      initialAnchor: _articleAnchor,
      initialScrollOffset: _articleScrollOffset,
      onActiveDictionaryChanged: _handleAggregateActiveDictionaryChanged,
      onOpenHeadword: (mdxPath, headword, anchor, sourceScrollOffset) {
        final source =
            entries.where((entry) => entry.mdxPath == mdxPath).firstOrNull;
        if (source == null) return Future.value();
        return _openLinkedHeadword(
          source,
          headword,
          anchor,
          sourceScrollOffset,
        );
      },
    );
    final articleSurface = compact
        ? reader
        : ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: reader,
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        articleSurface,
        _buildReaderQuickActions(),
      ],
    );
  }

  void _handleAggregateActiveDictionaryChanged(String mdxPath) {
    if (!mounted || _selectedMdxPath == mdxPath) return;
    if (!_availableEntries.any((entry) => entry.mdxPath == mdxPath)) return;
    setState(() {
      _selectedMdxPath = mdxPath;
      _articleAnchor = null;
      _articleScrollOffset = null;
    });
  }

  Widget _buildRetainedDictionaryReaders(
    List<DictionaryLibraryEntry> entries,
    DictionaryLibraryEntry selected, {
    required bool compact,
  }) {
    if (_readerPlatformPolicy.reuseRetainedReaderSlots) {
      return _buildReusableRetainedReaderSlots(
        entries,
        selected,
        compact: compact,
      );
    }
    final byPath = {for (final entry in entries) entry.mdxPath: entry};
    // LRU order decides which readers survive, but rendering in that order
    // moved Android platform views every time the selected dictionary changed.
    // Keep children in immutable library order so a tab switch changes only
    // IndexedStack.index and the native WebViews stay attached.
    final paths = retainedReaderDisplayOrder(
      libraryPaths: entries.map((entry) => entry.mdxPath),
      retainedLruPaths: _retainedReaderPaths.where(byPath.containsKey),
      selectedPath: selected.mdxPath,
    );
    return IndexedStack(
      index: paths.indexOf(selected.mdxPath),
      sizing: StackFit.expand,
      children: [
        for (final path in paths)
          _buildSelectedDictionaryArticle(
            byPath[path]!,
            _articlesByDictionary[path],
            compact: compact,
          ),
      ],
    );
  }

  Widget _buildReusableRetainedReaderSlots(
    List<DictionaryLibraryEntry> entries,
    DictionaryLibraryEntry selected, {
    required bool compact,
  }) {
    final byPath = {for (final entry in entries) entry.mdxPath: entry};
    final selectedSlot = _retainedReaderSlots.indexOf(selected.mdxPath);
    final fallbackSlot = _retainedReaderSlots.indexWhere(
      (path) => path != null && byPath.containsKey(path),
    );
    return IndexedStack(
      index: selectedSlot >= 0
          ? selectedSlot
          : fallbackSlot >= 0
              ? fallbackSlot
              : 0,
      sizing: StackFit.expand,
      children: [
        for (var index = 0; index < _retainedReaderSlots.length; index++)
          if (_retainedReaderSlots[index] case final path?
              when byPath[path] != null)
            _buildSelectedDictionaryArticle(
              byPath[path]!,
              _articlesByDictionary[path],
              compact: compact,
              readerKey: ValueKey('reusable-dictionary-reader-$index'),
            )
          else
            SizedBox.expand(
              key: ValueKey('empty-dictionary-reader-slot-$index'),
            ),
      ],
    );
  }

  Widget _buildSelectedDictionaryArticle(
      DictionaryLibraryEntry entry, List<Article>? articles,
      {required bool compact, Key? readerKey}) {
    if (articles == null) {
      return _buildEmptyState(
        icon: Icons.hourglass_top_rounded,
        title: '正在查询「${entry.title}」',
        message: '当前词典优先显示，其他词典仍会在后台继续查询。',
        loading: true,
      );
    }
    if (articles.isEmpty) {
      final hasResult =
          _articlesByDictionary.values.any((candidate) => candidate.isNotEmpty);
      return _buildEmptyState(
        icon: hasResult ? Icons.menu_book_outlined : Icons.search_off_rounded,
        title: hasResult ? '「${entry.title}」未收录该词' : '没有找到该词',
        message: hasResult ? '可在上方快速切换到已有结果的词典。' : '可以检查拼写，或尝试更短的词形。',
      );
    }
    final savedScrollOffset = _readerPositionCache.get(
      entry.mdxPath,
      _readerQuery,
    );
    final reader = ArticlePage(
      key: readerKey ?? ValueKey('dictionary-reader-${entry.mdxPath}'),
      article: articles.first,
      engine: widget.engine,
      localScriptCompatibilityEnabled: true,
      embedded: true,
      controller: _articleControllers.putIfAbsent(
        entry.mdxPath,
        ArticlePageController.new,
      ),
      initialAnchor: entry.mdxPath == _selectedMdxPath ? _articleAnchor : null,
      initialScrollOffset: entry.mdxPath == _selectedMdxPath
          ? _articleScrollOffset ?? savedScrollOffset
          : savedScrollOffset,
      textScale: _textScale,
      onDocumentRendered: () => _preloadNextDictionaryReader(entry.mdxPath),
      onOpenHeadword: (headword, anchor, sourceScrollOffset) =>
          _openLinkedHeadword(
        entry,
        headword,
        anchor,
        sourceScrollOffset,
      ),
    );
    // A phone reader is intentionally edge-to-edge: dictionary CSS gets the
    // available width instead of being nested in another rounded card.
    final articleSurface = compact
        ? reader
        : ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: reader,
          );
    // Attach floating reading actions to the actual article rather than the
    // whole destination. On wide layouts this keeps them in the lower-right
    // of the text, not over the dictionary-result rail.
    return Stack(
      fit: StackFit.expand,
      children: [
        articleSurface,
        _buildReaderQuickActions(),
      ],
    );
  }

  List<String> _adoptRetainedReaderPaths(Iterable<String> paths) {
    final retained = List<String>.unmodifiable(paths);
    if (_readerPlatformPolicy.reuseRetainedReaderSlots) {
      _retainedReaderSlots = assignRetainedReaderSlots(
        currentSlots: _retainedReaderSlots,
        retainedLruPaths: retained,
        slotCount: _readerPlatformPolicy.maximumRetainedReaders,
      );
    }
    return retained;
  }

  void _rememberCurrentReaderPosition() {
    if (!_readerPlatformPolicy.reuseRetainedReaderSlots) return;
    final query = _readerQuery.trim();
    final path = _selectedMdxPath;
    if (query.isEmpty || path == null) return;
    final offset = _articleControllers[path]?.lastKnownScrollOffset ?? 0;
    _readerPositionCache.put(path, query, offset);
  }

  List<String> _retainReaderPath(List<String> current, String? path) {
    if (path == null) return current;
    final next = List<String>.of(current)
      ..remove(path)
      ..add(path);
    while (next.length > _maximumRetainedReaders) {
      next.removeAt(0);
    }
    return next;
  }

  void _preloadNextDictionaryReader(String renderedPath) {
    _readerPreloadDelay?.cancel();
    if (!_readerPlatformPolicy.preloadAdjacentDictionaryReader) return;
    final query = _readerQuery;
    _readerPreloadDelay = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || query != _queryController.text.trim()) return;
      if (!_retainedReaderPaths.contains(renderedPath) ||
          _retainedReaderPaths.length >= _maximumRetainedReaders) {
        return;
      }
      final nextPath = _availableEntries
          .map((entry) => entry.mdxPath)
          .where((path) => !_retainedReaderPaths.contains(path))
          .where((path) => _articlesByDictionary[path]?.isNotEmpty ?? false)
          .firstOrNull;
      if (nextPath == null) return;
      setState(() {
        _retainedReaderPaths = _adoptRetainedReaderPaths(
          _retainReaderPath(
            _retainedReaderPaths,
            nextPath,
          ),
        );
      });
    });
  }

  Widget _buildDictionaryJumpRail(List<DictionaryLibraryEntry> entries) {
    final colors = Theme.of(context).colorScheme;
    final foundCount = entries
        .where((entry) =>
            _articlesByDictionary[entry.mdxPath]?.isNotEmpty ?? false)
        .length;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '在以下词典中找到',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 10),
            child: Text(
              _isSearching ? '正在查询…' : '$foundCount 本词典',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 3),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final selected = entry.mdxPath == _selectedMdxPath;
                final pending = _articlesByDictionary[entry.mdxPath] == null;
                return Material(
                  color: selected
                      ? colors.primaryContainer.withValues(alpha: 0.72)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _selectDictionaryResult(entry),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.menu_book_rounded,
                            size: 18,
                            color: selected ? colors.primary : colors.outline,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: entry.title,
                              child: Text(
                                entry.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                          if (pending)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: SizedBox.square(
                                dimension: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDictionaryScopeSelector({required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    final entries = _availableEntries;
    final activeGroup = _dictionaryGroupSnapshot.groups
        .where((group) => group.id == _activeDictionaryScopeId)
        .firstOrNull;
    final selected =
        entries.where((entry) => entry.mdxPath == _selectedMdxPath).firstOrNull;
    final positionLabel = dictionaryResultPositionLabel(
      entries.map((entry) => entry.mdxPath),
      _selectedMdxPath,
    );
    final scopeName = _dictionaryScopeName(_activeDictionaryScopeId);
    final dictionaryName = selected?.title;
    final label = _supportsDictionaryGroups
        ? dictionaryName == null
            ? scopeName
            : '$scopeName · $dictionaryName'
        : dictionaryName ?? '全部词典';
    final showStepButtons =
        compact && isLumaLexDesktop && !widget.processTextMode;
    final previousResult =
        showStepButtons ? _adjacentDictionaryResult(forward: false) : null;
    final nextResult =
        showStepButtons ? _adjacentDictionaryResult(forward: true) : null;
    // The lookup page already has 12 dp horizontal padding on phones. Adding
    // another 12 dp keeps the gesture surface at least 24 dp away from the
    // physical edges used by Android back/quick-window gestures. The full
    // remaining row stays stable even when the visible chip changes width.
    final selector = Semantics(
      button: true,
      label: '当前词典 $label，$positionLabel',
      hint: '点按打开词典列表，向左滑切换下一本有结果的词典，向右滑切换上一本',
      onTap: _allAvailableEntries.isEmpty ? null : _showDictionaryScopeSheet,
      onIncrease: () => _switchDictionaryResult(forward: true),
      onDecrease: () => _switchDictionaryResult(forward: false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _dictionarySelectorDragDistance = 0;
        },
        onHorizontalDragUpdate: (details) {
          _dictionarySelectorDragDistance += details.delta.dx;
        },
        onHorizontalDragCancel: () {
          _dictionarySelectorDragDistance = 0;
        },
        onHorizontalDragEnd: _finishDictionarySelectorDrag,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 44 : 48),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow.withValues(alpha: 0.46),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExcludeSemantics(
                      child: Material(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _allAvailableEntries.isEmpty
                              ? null
                              : _showDictionaryScopeSheet,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              compact ? 8 : 11,
                              10,
                              compact ? 8 : 11,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  activeGroup == null
                                      ? Icons.menu_book_rounded
                                      : Icons.folder_rounded,
                                  size: 18,
                                  color: activeGroup == null
                                      ? colors.primary
                                      : _dictionaryGroupColor(activeGroup),
                                ),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 190),
                                    child: Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    positionLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: colors.onPrimaryContainer,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                                Icon(Icons.keyboard_arrow_down_rounded,
                                    size: 19, color: colors.onSurfaceVariant),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!showStepButtons)
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      child: Icon(
                        Icons.swipe_rounded,
                        size: 18,
                        color: colors.onSurfaceVariant.withValues(alpha: 0.42),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    Widget stepButton({required bool forward, required bool enabled}) =>
        IconButton.outlined(
          key: ValueKey(forward
              ? 'compact-dictionary-next'
              : 'compact-dictionary-previous'),
          tooltip: forward ? '下一本有结果的词典' : '上一本有结果的词典',
          onPressed:
              enabled ? () => _switchDictionaryResult(forward: forward) : null,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(44),
            padding: EdgeInsets.zero,
            side: BorderSide(color: colors.outlineVariant),
          ),
          icon: Icon(forward
              ? Icons.chevron_right_rounded
              : Icons.chevron_left_rounded),
        );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 0),
      child: showStepButtons
          ? Row(
              children: [
                stepButton(forward: false, enabled: previousResult != null),
                const SizedBox(width: 8),
                Expanded(child: selector),
                const SizedBox(width: 8),
                stepButton(forward: true, enabled: nextResult != null),
              ],
            )
          : selector,
    );
  }

  Future<void> _showDictionaryScopeSheet() async {
    if (_allAvailableEntries.isEmpty) return;
    var visibleScopeId = _activeDictionaryScopeId;
    var switchingScope = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final entries = dictionaryEntriesForScope(
            _allAvailableEntries,
            visibleScopeId,
          );
          final scopeChoices =
              <({String id, String name, int count, Color? color})>[
            (
              id: DictionaryGroupScope.all,
              name: '全部',
              count: _allAvailableEntries.length,
              color: null,
            ),
            for (final group in _dictionaryGroupSnapshot.groups)
              (
                id: group.id,
                name: group.name,
                count: dictionaryEntriesForScope(
                  _allAvailableEntries,
                  group.id,
                ).length,
                color: _dictionaryGroupColor(group),
              ),
            (
              id: DictionaryGroupScope.ungrouped,
              name: '未分组',
              count: dictionaryEntriesForScope(
                _allAvailableEntries,
                DictionaryGroupScope.ungrouped,
              ).length,
              color: null,
            ),
          ];
          return SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 2, 24, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '词典结果',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (switchingScope)
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                  ),
                  if (_supportsDictionaryGroups)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          for (final scope in scopeChoices)
                            Padding(
                              padding: const EdgeInsets.only(right: 7),
                              child: ChoiceChip(
                                selected: visibleScopeId == scope.id,
                                avatar: Icon(
                                  scope.id == DictionaryGroupScope.all
                                      ? Icons.layers_outlined
                                      : scope.id ==
                                              DictionaryGroupScope.ungrouped
                                          ? Icons.inbox_outlined
                                          : Icons.folder_rounded,
                                  size: 18,
                                  color: scope.color ??
                                      Theme.of(sheetContext)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                                label: Text('${scope.name} ${scope.count}'),
                                onSelected: switchingScope
                                    ? null
                                    : (selected) async {
                                        if (!selected ||
                                            visibleScopeId == scope.id) {
                                          return;
                                        }
                                        setSheetState(() {
                                          visibleScopeId = scope.id;
                                          switchingScope = true;
                                        });
                                        await _selectDictionaryScope(scope.id);
                                        if (sheetContext.mounted) {
                                          setSheetState(
                                              () => switchingScope = false);
                                        }
                                      },
                              ),
                            ),
                        ],
                      ),
                    ),
                  Flexible(
                    child: entries.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                '这个分组里暂时没有已启用且可访问的词典。',
                                textAlign: TextAlign.center,
                                style: Theme.of(sheetContext)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(sheetContext)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: entries.length,
                            itemBuilder: (context, index) {
                              final entry = entries[index];
                              final selected =
                                  entry.mdxPath == _selectedMdxPath;
                              final articles =
                                  _articlesByDictionary[entry.mdxPath];
                              final pending = articles == null;
                              final found = articles?.isNotEmpty ?? false;
                              return ListTile(
                                leading: Icon(
                                  selected
                                      ? Icons.check_circle_rounded
                                      : Icons.menu_book_outlined,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                                title: Text(
                                  entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  pending
                                      ? '正在查询…'
                                      : found
                                          ? '已找到词条'
                                          : '未收录该词',
                                ),
                                trailing: pending
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : null,
                                onTap: switchingScope
                                    ? null
                                    : () {
                                        Navigator.of(sheetContext).pop();
                                        _selectDictionaryResult(entry);
                                      },
                              );
                            },
                          ),
                  ),
                  if (_supportsDictionaryGroups && !widget.processTextMode)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: TextButton.icon(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _selectDestination(_AppDestination.dictionaries);
                          },
                          icon: const Icon(Icons.settings_outlined, size: 18),
                          label: const Text('管理分组'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildReaderQuickActions() {
    // The selected-text window owns persistent reading actions in its title
    // bar. Never overlay them on its deliberately small article viewport.
    if (widget.processTextMode) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final favorite = _isFavorite(_queryController.text);
    return Positioned(
      right: 4,
      bottom: 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showReaderTextControls) ...[
            Material(
              color: colors.surfaceContainerLowest,
              elevation: 4,
              shadowColor: const Color(0x33000000),
              borderRadius: BorderRadius.circular(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '放大字号',
                    onPressed: _currentTextScale >= 2
                        ? null
                        : () => _setCurrentTextScale(_currentTextScale + 0.1),
                    icon: const Icon(Icons.add_rounded),
                  ),
                  Text(
                    '${(_currentTextScale * 100).round()}%',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  IconButton(
                    tooltip: '缩小字号',
                    onPressed: _currentTextScale <= 0.6
                        ? null
                        : () => _setCurrentTextScale(_currentTextScale - 0.1),
                    icon: const Icon(Icons.remove_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          ReaderFavoriteButton(
            favorite: favorite,
            onPressed: () => _toggleFavorite(_queryController.text),
          ),
        ],
      ),
    );
  }

  void _selectDictionaryResult(DictionaryLibraryEntry entry) {
    // Keep recent same-word readers in the IndexedStack. A result-tab switch
    // then exposes its existing WebView instead of disposing it and parsing
    // the entry again on a later return.
    if (_selectedMdxPath == entry.mdxPath) {
      return;
    }
    _rememberCurrentReaderPosition();
    setState(() {
      final previous = _selectedMdxPath;
      _selectedMdxPath = entry.mdxPath;
      _retainedReaderPaths = _adoptRetainedReaderPaths(
        _retainReaderPath(
          _retainReaderPath(_retainedReaderPaths, previous),
          entry.mdxPath,
        ),
      );
      _articleAnchor = null;
      _articleScrollOffset = null;
    });
    if (_readerPlatformPolicy.aggregateDictionaryResults) {
      unawaited(_aggregateArticleController.showDictionary(entry.mdxPath));
    }
    _revealSelectedDesktopDictionary(_desktopDictionaryInlineScrollController);
    _revealSelectedDesktopDictionary(_desktopDictionaryPopupScrollController);
  }

  void _finishDictionarySelectorDrag(DragEndDetails details) {
    final distance = _dictionarySelectorDragDistance;
    final velocity = details.primaryVelocity ?? 0;
    _dictionarySelectorDragDistance = 0;
    final direction = distance.abs() >= 32
        ? distance
        : velocity.abs() >= 280
            ? velocity
            : 0;
    if (direction == 0) return;
    _switchDictionaryResult(forward: direction < 0);
  }

  DictionaryLibraryEntry? _adjacentDictionaryResult({required bool forward}) {
    final entries = _availableEntries;
    final resultPaths = entries
        .map((entry) => entry.mdxPath)
        .where((path) => _articlesByDictionary[path]?.isNotEmpty ?? false)
        .toSet();
    final targetPath = adjacentDictionaryResultPath(
      orderedMdxPaths: entries.map((entry) => entry.mdxPath),
      resultMdxPaths: resultPaths,
      selectedMdxPath: _selectedMdxPath,
      forward: forward,
    );
    if (targetPath == null) return null;
    return entries.firstWhere((entry) => entry.mdxPath == targetPath);
  }

  void _switchDictionaryResult({required bool forward}) {
    final target = _adjacentDictionaryResult(forward: forward);
    if (target == null) return;
    unawaited(HapticFeedback.selectionClick());
    _selectDictionaryResult(target);
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    bool loading = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 42, vertical: 38),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            colors.primaryContainer,
                            colors.secondaryContainer,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: loading
                          ? Padding(
                              padding: const EdgeInsets.all(23),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: colors.primary,
                              ),
                            )
                          : Icon(icon, size: 34, color: colors.primary),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                              ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.55,
                          ),
                    ),
                    if (actionLabel != null && onAction != null) ...[
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: onAction,
                        icon: Icon(
                          _libraryEntries.isEmpty
                              ? Icons.add_rounded
                              : Icons.settings_rounded,
                        ),
                        label: Text(actionLabel),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 46),
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _supportsDictionaryGroups =>
      _readerPlatformPolicy.supportsDictionaryGroups;

  String get _activeDictionaryScopeId => _supportsDictionaryGroups
      ? _dictionaryGroupSnapshot.activeScopeId
      : DictionaryGroupScope.all;

  bool _entryMatchesActiveDictionaryScope(DictionaryLibraryEntry entry) =>
      dictionaryEntriesForScope([entry], _activeDictionaryScopeId).isNotEmpty;

  List<DictionaryLibraryEntry> get _allAvailableEntries => _libraryEntries
      .where(
        (entry) =>
            entry.isEnabled && _availableMdxPaths.contains(entry.mdxPath),
      )
      .toList(growable: false);

  List<DictionaryLibraryEntry> get _availableEntries =>
      dictionaryEntriesForScope(_allAvailableEntries, _activeDictionaryScopeId);
}

class _RenameDictionaryDialog extends StatefulWidget {
  const _RenameDictionaryDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDictionaryDialog> createState() =>
      _RenameDictionaryDialogState();
}

class _RenameDictionaryDialogState extends State<_RenameDictionaryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialName.length,
      );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_nameController.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('修改词典显示名称'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '显示名称',
              helperText: '只修改 LumaLex 中的名称，不会更改词典文件。',
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '显示名称不能为空' : null,
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('保存'),
          ),
        ],
      );
}

class _DictionaryGroupNameDialog extends StatefulWidget {
  const _DictionaryGroupNameDialog({
    required this.title,
    required this.initialName,
    required this.validator,
  });

  final String title;
  final String initialName;
  final String? Function(String value) validator;

  @override
  State<_DictionaryGroupNameDialog> createState() =>
      _DictionaryGroupNameDialogState();
}

class _DictionaryGroupNameDialogState
    extends State<_DictionaryGroupNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _controller,
            autofocus: true,
            maxLength: 30,
            decoration: const InputDecoration(
              labelText: '分组名称',
              helperText: '只修改 LumaLex 中的分组，不会更改词典文件。',
            ),
            validator: (value) => widget.validator(value ?? ''),
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _submit, child: const Text('保存')),
        ],
      );
}
