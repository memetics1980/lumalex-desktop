import 'dart:io';

/// Platform-owned limits and lifecycle choices for the dictionary reader.
///
/// Keep memory, WebView reveal, and foreground-recovery decisions here rather
/// than scattering platform checks through shared reader widgets. Product
/// behavior remains shared; these values capture the platform constraints
/// needed to make that behavior reliable.
final class ReaderPlatformPolicy {
  const ReaderPlatformPolicy({
    required this.maximumRetainedReaders,
    required this.resourceCacheByteLimit,
    required this.singleCachedResourceByteLimit,
    required this.revealArticleAfterSetup,
    required this.recoverReaderAfterForeground,
    required this.keepArticlePlatformViewAlive,
    required this.aggregateDictionaryResults,
    required this.reuseRetainedReaderSlots,
    required this.preloadAdjacentDictionaryReader,
    required this.showWideDictionaryJumpRail,
    required this.supportsDictionaryGroups,
    required this.adaptiveReaderRetention,
    required this.memoryPressureRetainedReaders,
  });

  /// Maximum live article WebViews for one lookup.
  final int maximumRetainedReaders;

  /// Aggregate memory budget for decoded dictionary resources.
  final int resourceCacheByteLimit;

  /// Largest individual dictionary resource held in the memory cache.
  final int singleCachedResourceByteLimit;

  /// Android hides the first Chromium frame until the configured text scale
  /// and native bridges are ready, preventing a visible text-size jump.
  final bool revealArticleAfterSetup;

  /// iOS can reclaim WebKit's loopback connection while suspended, so it
  /// validates and recovers the reader after a foreground transition.
  final bool recoverReaderAfterForeground;

  /// Keeps Android's native WebView instance attached to its logical article
  /// reader while Flutter moves or temporarily rebuilds the platform surface.
  final bool keepArticlePlatformViewAlive;

  /// Loads every matching dictionary document into one native WebView and
  /// switches the visible iframe without navigating the host document.
  final bool aggregateDictionaryResults;

  /// Reassigns new LRU documents into a bounded set of stable native views.
  /// iOS avoids repeated WKWebView allocation without retaining more pages.
  final bool reuseRetainedReaderSlots;

  /// Prepares one additional retained reader after the selected document has
  /// rendered. iOS fills its second slot only after an explicit dictionary
  /// switch so an ordinary lookup starts with a single WKWebView.
  final bool preloadAdjacentDictionaryReader;

  /// Shows a persistent dictionary-result list beside the article on a wide
  /// desktop window. Mobile platforms already expose the same navigation in
  /// the reader toolbar and through swipe gestures, including wide iPads.
  final bool showWideDictionaryJumpRail;

  /// Whether this platform exposes the shared dictionary grouping UI.
  final bool supportsDictionaryGroups;

  /// Whether the native device memory class selects the normal reader limit.
  final bool adaptiveReaderRetention;

  /// Emergency reader limit after Flutter receives a memory-pressure signal.
  final int memoryPressureRetainedReaders;

  int retainedReadersForMemory({
    required int memoryClassMb,
    required bool isLowRamDevice,
  }) {
    if (!adaptiveReaderRetention) return maximumRetainedReaders;
    if (isLowRamDevice || (memoryClassMb > 0 && memoryClassMb <= 192)) {
      return 2;
    }
    if (memoryClassMb >= 512) return 5;
    return 3;
  }

  static ReaderPlatformPolicy get current =>
      forOperatingSystem(Platform.operatingSystem);

  static ReaderPlatformPolicy forOperatingSystem(String operatingSystem) {
    return switch (operatingSystem.toLowerCase()) {
      'android' => _android,
      'ios' => _ios,
      'windows' => _windows,
      'macos' => _macos,
      _ => _desktop,
    };
  }

  static const _android = ReaderPlatformPolicy(
    maximumRetainedReaders: 3,
    resourceCacheByteLimit: 64 * 1024 * 1024,
    singleCachedResourceByteLimit: 8 * 1024 * 1024,
    revealArticleAfterSetup: true,
    recoverReaderAfterForeground: false,
    keepArticlePlatformViewAlive: true,
    aggregateDictionaryResults: true,
    reuseRetainedReaderSlots: false,
    preloadAdjacentDictionaryReader: true,
    showWideDictionaryJumpRail: false,
    supportsDictionaryGroups: true,
    adaptiveReaderRetention: true,
    memoryPressureRetainedReaders: 1,
  );

  static const _ios = ReaderPlatformPolicy(
    maximumRetainedReaders: 2,
    resourceCacheByteLimit: 16 * 1024 * 1024,
    singleCachedResourceByteLimit: 2 * 1024 * 1024,
    revealArticleAfterSetup: false,
    recoverReaderAfterForeground: true,
    keepArticlePlatformViewAlive: false,
    aggregateDictionaryResults: false,
    reuseRetainedReaderSlots: true,
    preloadAdjacentDictionaryReader: false,
    showWideDictionaryJumpRail: false,
    supportsDictionaryGroups: true,
    adaptiveReaderRetention: false,
    memoryPressureRetainedReaders: 1,
  );

  static const _windows = ReaderPlatformPolicy(
    maximumRetainedReaders: 3,
    resourceCacheByteLimit: 128 * 1024 * 1024,
    singleCachedResourceByteLimit: 16 * 1024 * 1024,
    revealArticleAfterSetup: false,
    recoverReaderAfterForeground: false,
    keepArticlePlatformViewAlive: false,
    // WebView2 is substantially more stable when one long-lived host owns
    // the dictionary frames. Switching dictionaries and resizing the window
    // then update the existing page instead of destroying and recreating a
    // native WebView for each result.
    aggregateDictionaryResults: true,
    reuseRetainedReaderSlots: false,
    preloadAdjacentDictionaryReader: false,
    // The touch-sized selector above the article is the single dictionary
    // switcher on Windows. A second rail wastes horizontal space and changes
    // the platform-view tree when a window crosses the wide breakpoint.
    showWideDictionaryJumpRail: false,
    supportsDictionaryGroups: true,
    adaptiveReaderRetention: false,
    memoryPressureRetainedReaders: 3,
  );

  // macOS keeps separate WebKit readers and the wide dictionary rail while
  // sharing dictionary groups with Windows. WebView2 workarounds stay Windows-only.
  static const _macos = ReaderPlatformPolicy(
    maximumRetainedReaders: 3,
    resourceCacheByteLimit: 64 * 1024 * 1024,
    singleCachedResourceByteLimit: 8 * 1024 * 1024,
    revealArticleAfterSetup: false,
    recoverReaderAfterForeground: false,
    keepArticlePlatformViewAlive: false,
    aggregateDictionaryResults: false,
    reuseRetainedReaderSlots: false,
    preloadAdjacentDictionaryReader: true,
    showWideDictionaryJumpRail: true,
    supportsDictionaryGroups: true,
    adaptiveReaderRetention: false,
    memoryPressureRetainedReaders: 3,
  );

  // Preserve the former non-iOS behavior for other desktop builds, where the
  // mobile WebView reveal and iOS recovery workarounds do not apply.
  static const _desktop = ReaderPlatformPolicy(
    maximumRetainedReaders: 3,
    resourceCacheByteLimit: 64 * 1024 * 1024,
    singleCachedResourceByteLimit: 8 * 1024 * 1024,
    revealArticleAfterSetup: false,
    recoverReaderAfterForeground: false,
    keepArticlePlatformViewAlive: false,
    aggregateDictionaryResults: false,
    reuseRetainedReaderSlots: false,
    preloadAdjacentDictionaryReader: true,
    showWideDictionaryJumpRail: true,
    supportsDictionaryGroups: false,
    adaptiveReaderRetention: false,
    memoryPressureRetainedReaders: 3,
  );
}
