import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'platform/android_process_text_window.dart';
import 'platform/reader_platform_policy.dart';
import 'screens/home_page.dart';
import 'services/dictionary_engine.dart';
import 'services/dictionary_groups.dart';
import 'services/dictionary_library.dart';
import 'services/rust_dictionary_engine.dart';
import 'services/windows_app_settings.dart';
import 'services/word_records.dart';
import 'src/rust/api/dictionary.dart' as rust;
import 'src/rust/frb_generated.dart';

const _lightSystemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarColor: Color(0xFFF3F7F7),
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

// Compile-time-only integration hook used to exercise the native tray path
// without modifying a developer's real SharedPreferences file. Normal builds
// never define this value and always use persistent user settings below.
const _windowsTrayIntegrationTest =
    bool.fromEnvironment('LUMALEX_TRAY_INTEGRATION_TEST');

/// Keeps scrollable surfaces usable with Windows touch, pen and precision
/// touchpads without turning ordinary mouse drags into mobile-style scrolling.
class LumaLexScrollBehavior extends MaterialScrollBehavior {
  const LumaLexScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      };
}

Future<void> main() => _runDictionaryApp();

/// Separate entrypoint used by Android's native PROCESS_TEXT activity.
///
/// Keeping this entrypoint distinct lets Android present a compact floating
/// window without changing the normal launcher activity or any iOS behavior.
@pragma('vm:entry-point')
Future<void> processTextMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final selectedText = await AndroidProcessTextWindow.selectedText();
  await _runDictionaryApp(
    initialQuery: selectedText,
    processTextMode: true,
  );
}

Future<void> _runDictionaryApp({
  String initialQuery = '',
  bool processTextMode = false,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(_lightSystemUiOverlayStyle);
  await DictionaryRust.init();
  // Key indexes are source-bound and disposable, but rebuilding one after an
  // Android cache eviction causes a conspicuous first-lookup pause. Keep
  // these small derived artifacts with application support data instead of
  // the OS-evictable article/resource caches.
  final supportDirectory = await getApplicationSupportDirectory();
  final indexDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}key-indexes',
  );
  await rust.configureIndexCache(
    indexCacheDirectory: indexDirectory.path,
  );
  runApp(
    DictionaryApp(
      engine: RustDictionaryEngine(),
      dictionaryGroups: PreferencesDictionaryGroupsStore(),
      library: PersistentDictionaryLibrary(),
      wordRecords: PreferencesWordRecordsStore(),
      windowsAppSettings: _windowsTrayIntegrationTest
          ? InMemoryWindowsAppSettingsStore(
              closeBehavior: WindowsCloseBehavior.hideToTray,
              trayNotificationShown: true,
            )
          : PreferencesWindowsAppSettingsStore(),
      initialQuery: initialQuery,
      processTextMode: processTextMode,
    ),
  );
}

class DictionaryApp extends StatelessWidget {
  const DictionaryApp({
    super.key,
    this.engine,
    this.dictionaryGroups,
    this.library,
    this.wordRecords,
    this.windowsAppSettings,
    this.initialQuery = '',
    this.processTextMode = false,
    this.readerPlatformPolicy,
  });

  final DictionaryEngine? engine;
  final DictionaryGroupsStore? dictionaryGroups;
  final DictionaryLibrary? library;
  final WordRecordsStore? wordRecords;
  final WindowsAppSettingsStore? windowsAppSettings;
  final String initialQuery;
  final bool processTextMode;
  final ReaderPlatformPolicy? readerPlatformPolicy;

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFF087E87);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: Brightness.light,
      surface: const Color(0xFFF8FAFA),
    ).copyWith(
      primary: brand,
      secondary: const Color(0xFF2D6CDF),
      tertiary: const Color(0xFFF2B84B),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF2F6F6),
      surfaceContainer: const Color(0xFFEAF1F1),
      surfaceContainerHigh: const Color(0xFFE1EBEB),
      outline: const Color(0xFF9AAEAE),
      outlineVariant: const Color(0xFFD5E0E0),
    );
    return MaterialApp(
      title: 'LumaLex',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      scrollBehavior: const LumaLexScrollBehavior(),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: _lightSystemUiOverlayStyle,
        child: child ?? const SizedBox.shrink(),
      ),
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        // Bundle one OFL-licensed family with complete Simplified Chinese and
        // Latin coverage. This avoids per-glyph fallback between Windows UI
        // fonts, which made adjacent Chinese characters look uneven.
        fontFamily: 'NotoSansSC',
        // Flutter normally applies a denser desktop theme on Windows. Keep
        // standard Material hit targets so the same controls remain reliable
        // on touch-enabled laptops and convertible PCs.
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        scaffoldBackgroundColor: const Color(0xFFF3F7F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: _lightSystemUiOverlayStyle,
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFDCE5E5),
          thickness: 1,
        ),
        scrollbarTheme: ScrollbarThemeData(
          interactive: true,
          radius: const Radius.circular(8),
          thickness: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) ? 10 : 8,
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFFF8FAFA),
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      home: HomePage(
        engine: engine ?? const UnavailableDictionaryEngine(),
        dictionaryGroups: dictionaryGroups ?? InMemoryDictionaryGroupsStore(),
        library: library ?? InMemoryDictionaryLibrary(),
        wordRecords: wordRecords ?? InMemoryWordRecordsStore(),
        windowsAppSettings:
            windowsAppSettings ?? InMemoryWindowsAppSettingsStore(),
        initialQuery: initialQuery,
        processTextMode: processTextMode,
        readerPlatformPolicy: readerPlatformPolicy,
      ),
    );
  }
}
