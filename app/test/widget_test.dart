// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_dictionary/main.dart';
import 'package:local_dictionary/models/article.dart';
import 'package:local_dictionary/models/dictionary_library_entry.dart';
import 'package:local_dictionary/platform/reader_platform_policy.dart';
import 'package:local_dictionary/platform/windows_screen_lookup.dart';
import 'package:local_dictionary/screens/home_page.dart';
import 'package:local_dictionary/services/dictionary_engine.dart';
import 'package:local_dictionary/services/dictionary_library.dart';
import 'package:local_dictionary/services/word_records.dart';

void main() {
  test('desktop destination pages expand on Windows', () {
    expect(
      destinationPageMaxWidthForOperatingSystem(
        'windows',
        fallback: 920,
      ),
      2400,
    );
    expect(
      destinationPageMaxWidthForOperatingSystem(
        'linux',
        fallback: 920,
      ),
      920,
    );
  });

  testWidgets('shows the empty local-dictionary state', (tester) async {
    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('建立你的离线词典库'), findsOneWidget);
    expect(find.text('导入第一本词典'), findsOneWidget);
  });

  testWidgets('Windows settings live below the primary destinations',
      (tester) async {
    const lifecycleChannel =
        MethodChannel('local_dictionary/windows_window_lifecycle');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      lifecycleChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycleChannel, null),
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    final lookupDestination = find.byKey(
      const PageStorageKey<String>('lookup-destination'),
      skipOffstage: false,
    );
    final lookupElementBeforeSettings = lookupDestination.evaluate().single;
    expect(find.byKey(const ValueKey('settings-navigation-button')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-navigation-button')));
    await tester.pumpAndSettle();

    // Opening settings must only hide the lookup destination. Removing it
    // would dispose and recreate the native WebView, reloading the article
    // when the user returns.
    expect(lookupDestination, findsOneWidget);
    expect(
      identical(
        lookupElementBeforeSettings,
        lookupDestination.evaluate().single,
      ),
      isTrue,
    );
    expect(find.text('关闭主窗口时'), findsOneWidget);
    expect(find.text('隐藏到托盘'), findsOneWidget);
    expect(find.text('屏幕取词'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('windows-screen-lookup-toggle')),
      findsOneWidget,
    );
    expect(find.text('AI 语境释义'), findsOneWidget);
    expect(find.textContaining('复制模式'), findsWidgets);
    expect(
      find.byKey(const ValueKey('windows-screen-lookup-ai-toggle')),
      findsOneWidget,
    );
    final shortcutControl =
        tester.widget<DropdownButtonFormField<WindowsScreenLookupShortcut>>(
      find.byKey(const ValueKey('windows-screen-lookup-shortcut')),
    );
    expect(shortcutControl.onChanged, isNotNull);
    await tester.fling(
      find.byKey(const PageStorageKey<String>('settings-page')),
      const Offset(0, -1000),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('0.1.0 · build 83 · Windows 便携版'), findsOneWidget);

    await tester.tap(find.text('查词'));
    await tester.pumpAndSettle();
    expect(
      identical(
        lookupElementBeforeSettings,
        lookupDestination.evaluate().single,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop dictionary launcher survives short and compact rails',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();
    const launcher = ValueKey('desktop-dictionary-launcher');
    expect(find.byKey(launcher), findsOneWidget);
    expect(find.text('词典结果'), findsOneWidget);

    tester.view.physicalSize = const Size(1280, 560);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(launcher), findsOneWidget);
    expect(find.text('词典结果'), findsNothing);
    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();
    expect(find.text('当前分组没有可用词典'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(launcher));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(launcher)));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    expect(find.text('当前分组没有可用词典'), findsOneWidget);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump();
    expect(find.text('当前分组没有可用词典'), findsNothing);
    await mouse.removePointer();

    tester.view.physicalSize = const Size(900, 560);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byKey(launcher), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop rail switches the current lookup dictionary',
      (tester) async {
    const fileAccessChannel = MethodChannel('local_dictionary/file_access');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileAccessChannel, (call) async {
      if (call.method == 'restoreReadBookmark') return true;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(fileAccessChannel, null),
    );
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('lumalex-rail-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final library = InMemoryDictionaryLibrary();
    for (var index = 0; index < 2; index++) {
      final path = '${directory.path}/dictionary-$index.mdx';
      File(path).writeAsBytesSync(const [0]);
      await library.upsert(DictionaryLibraryEntry(
        title: 'Dictionary $index',
        mdxPath: path,
        importedAtMilliseconds: index,
      ));
    }

    await tester.pumpWidget(DictionaryApp(
      engine: const _AvailableDictionaryEngine(),
      library: library,
      initialQuery: 'lookup',
    ));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-dictionary-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('desktop-dictionary-1')));
    await tester.pump();
    final launcher = find.byKey(const ValueKey('desktop-dictionary-launcher'));
    expect(find.descendant(of: launcher, matching: find.text('Dictionary 1')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Windows layout keeps settings reachable',
      (tester) async {
    const lifecycleChannel =
        MethodChannel('local_dictionary/windows_window_lifecycle');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      lifecycleChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycleChannel, null),
    );
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('compact-settings-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compact-settings-button')));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsWidgets);
    expect(find.text('关闭主窗口时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Windows lookup shows dictionary step arrows',
      (tester) async {
    const fileAccessChannel = MethodChannel('local_dictionary/file_access');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileAccessChannel, (call) async {
      if (call.method == 'restoreReadBookmark') return true;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(fileAccessChannel, null),
    );
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('lumalex-compact-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final library = InMemoryDictionaryLibrary();
    for (var index = 0; index < 2; index++) {
      final path = '${directory.path}/dictionary-$index.mdx';
      File(path).writeAsBytesSync(const [0]);
      await library.upsert(DictionaryLibraryEntry(
        title: 'Dictionary $index',
        mdxPath: path,
        importedAtMilliseconds: index,
      ));
    }

    await tester.pumpWidget(DictionaryApp(
      engine: const _AvailableDictionaryEngine(),
      library: library,
      initialQuery: 'lookup',
    ));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();

    final previous = find.byKey(const ValueKey('compact-dictionary-previous'));
    final next = find.byKey(const ValueKey('compact-dictionary-next'));
    expect(previous, findsOneWidget);
    expect(next, findsOneWidget);
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state stays overflow-free in a short window',
      (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('uses bottom navigation on compact screens', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏词汇'), findsOneWidget);
  });

  testWidgets('1080p and 4K at 200 percent share the wide logical layout',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> expectWideLayout(Size physicalSize, double pixelRatio) async {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = pixelRatio;
      await tester.pumpWidget(const DictionaryApp());
      await tester.pumpAndSettle();

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(tester.takeException(), isNull);
    }

    await expectWideLayout(const Size(1920, 1080), 1);
    await expectWideLayout(const Size(3840, 2160), 2);
  });

  testWidgets('global desktop theme remains touch friendly', (tester) async {
    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final behavior = materialApp.scrollBehavior!;
    expect(behavior, isA<LumaLexScrollBehavior>());
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
    expect(behavior.dragDevices, contains(PointerDeviceKind.stylus));
    expect(behavior.dragDevices, contains(PointerDeviceKind.trackpad));

    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.textTheme.bodyMedium?.fontFamily, 'NotoSansSC');
    expect(theme.visualDensity, VisualDensity.standard);
    expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
  });

  testWidgets('process-text mode shows a compact floating lookup shell',
      (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const DictionaryApp(
        processTextMode: true,
        initialQuery: 'increase',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LumaLex'), findsOneWidget);
    expect(find.text('increase'), findsOneWidget);
    expect(find.byKey(const ValueKey('process-text-search-navigation')),
        findsOneWidget);
    final searchBar = tester.widget<SearchBar>(find.byType(SearchBar));
    expect(searchBar.constraints?.minHeight, 44);
    expect(searchBar.constraints?.maxHeight, 44);
    expect(find.byTooltip('调整字号'), findsOneWidget);
    expect(find.byTooltip('收藏单词'), findsOneWidget);
    expect(find.byTooltip('最大化或恢复窗口'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent text-size entry toggles without scrolling',
      (tester) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ReaderTextScaleToggleButton(
                key: const ValueKey('reader-text-scale-toggle'),
                expanded: expanded,
                onPressed: () => setState(() => expanded = !expanded),
              );
            },
          ),
        ),
      ),
    );

    final toggle = find.byKey(const ValueKey('reader-text-scale-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byTooltip('调整字号'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.byTooltip('收起字号调整'), findsOneWidget);
  });

  testWidgets('narrow lookup header uses a compact home action',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupHomeButton(iconOnly: true, onPressed: () {}),
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey('lookup-home-icon-button')), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('查词首页'), findsNothing);
    expect(find.byTooltip('返回查词首页'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupHomeButton(iconOnly: false, onPressed: () {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('lookup-home-labeled-button')),
        findsOneWidget);
    expect(find.text('查词首页'), findsOneWidget);
  });

  testWidgets('reader favorite keeps a transparent full-size tap target',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderFavoriteButton(
            favorite: false,
            onPressed: () => taps += 1,
          ),
        ),
      ),
    );

    final finder = find.byKey(const ValueKey('reader-favorite-button'));
    final button = tester.widget<IconButton>(finder);
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    expect(
      button.style?.minimumSize?.resolve(<WidgetState>{}),
      const Size.square(48),
    );
    await tester.tap(finder);
    expect(taps, 1);
  });

  testWidgets('foreground refreshes records written by a floating lookup',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wordRecords = InMemoryWordRecordsStore();

    await tester.pumpWidget(DictionaryApp(wordRecords: wordRecords));
    await tester.pumpAndSettle();

    // A PROCESS_TEXT window runs in another Flutter engine. Writing directly
    // to the shared store models that engine while this launcher keeps its
    // original in-memory snapshot.
    await wordRecords.saveHistory(['floating-history']);
    await wordRecords.saveFavorites(['floating-favorite']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    expect(find.text('floating-favorite'), findsOneWidget);

    await tester.tap(find.text('管理历史'));
    await tester.pumpAndSettle();
    expect(find.text('floating-history'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cold aggregate lookup restores all dictionaries before query',
      (tester) async {
    const fileAccessChannel = MethodChannel('local_dictionary/file_access');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileAccessChannel, (call) async {
      if (call.method == 'restoreReadBookmark') return true;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(fileAccessChannel, null),
    );

    final directory = Directory.systemTemp.createTempSync('lumalex-cold-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final library = InMemoryDictionaryLibrary();
    final paths = <String>[];
    for (var index = 0; index < 3; index++) {
      final path = '${directory.path}/dictionary-$index.mdx';
      File(path).writeAsBytesSync(const [0]);
      paths.add(path);
      await library.upsert(
        DictionaryLibraryEntry(
          title: 'Dictionary $index',
          mdxPath: path,
          importedAtMilliseconds: index,
        ),
      );
    }
    final engine = _RecordingDictionaryEngine();

    await tester.pumpWidget(
      DictionaryApp(
        engine: engine,
        library: library,
        initialQuery: 'lookup',
        readerPlatformPolicy:
            ReaderPlatformPolicy.forOperatingSystem('android'),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      for (var attempt = 0;
          attempt < 50 && engine.lookedUpPaths.toSet().length < paths.length;
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(engine.importedPaths.toSet(), paths.toSet());
    expect(engine.lookedUpPaths.toSet(), paths.toSet());
    expect(engine.firstLookupImportCount, paths.length);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('uses comfortable navigation sizing on wide tablets',
      (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue);
    expect(rail.minExtendedWidth, 244);
    expect(rail.selectedIconTheme?.size, 32);
    expect(rail.unselectedIconTheme?.size, 30);
    expect(rail.selectedLabelTextStyle?.fontSize, 17);
    expect(rail.unselectedLabelTextStyle?.fontSize, 17);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide iPad lookup does not show the desktop dictionary rail',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('lumalex-ipad-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final mdx = File('${directory.path}/test.mdx');
    mdx.writeAsBytesSync(const [0]);
    final library = InMemoryDictionaryLibrary();
    await library.upsert(
      DictionaryLibraryEntry(
        title: 'Test Dictionary',
        mdxPath: mdx.path,
        importedAtMilliseconds: 0,
      ),
    );

    await tester.pumpWidget(
      DictionaryApp(
        engine: const _AvailableDictionaryEngine(),
        library: library,
        initialQuery: 'lookup',
        readerPlatformPolicy: ReaderPlatformPolicy.forOperatingSystem('ios'),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('在以下词典中找到'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('condenses wordbook and dictionary headers on short phones',
      (tester) async {
    tester.view.physicalSize = const Size(390, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DictionaryApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    expect(find.byTooltip('管理历史'), findsOneWidget);
    expect(find.text('收藏词汇会保存在这里，并自动加入闪卡复习计划。'), findsNothing);

    await tester.tap(find.byIcon(Icons.library_books_outlined));
    await tester.pumpAndSettle();
    expect(find.byTooltip('导入词典'), findsOneWidget);
    expect(find.text('管理本地 MDX/MDD 文件，启用的词典会参与查词。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dictionary management rows do not select or leave the page',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('lumalex-library-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final mdx = File('${directory.path}/test.mdx');
    mdx.writeAsBytesSync(const [0]);
    final library = InMemoryDictionaryLibrary();
    await library.upsert(
      DictionaryLibraryEntry(
        title: 'Test Dictionary',
        mdxPath: mdx.path,
        importedAtMilliseconds: 0,
      ),
    );

    await tester.pumpWidget(
      DictionaryApp(
        engine: const _AvailableDictionaryEngine(),
        library: library,
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.library_books_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Desktop platforms group dictionaries. Expand the default ungrouped
    // section before asserting against the management row itself.
    final ungrouped = find.text('未分组');
    final usesGroupedLibrary = ungrouped.evaluate().isNotEmpty;
    if (usesGroupedLibrary) {
      await tester.tap(ungrouped);
      await tester.pump();
    }

    final row = find.ancestor(
      of: find.text('Test Dictionary'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.menu_book_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsNothing,
    );
    expect(tester.widget<ListTile>(row).onTap, isNull);

    await tester.tap(find.text('Test Dictionary'));
    await tester.pump();
    expect(find.text('Test Dictionary'), findsOneWidget);
    expect(
      find.byType(
        usesGroupedLibrary ? SliverReorderableList : ReorderableListView,
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a saved word enters the first flashcard review session',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wordRecords = InMemoryWordRecordsStore();
    await wordRecords.saveFavorites(['review']);

    await tester.pumpWidget(DictionaryApp(wordRecords: wordRecords));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.auto_stories_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复习'));
    await tester.pumpAndSettle();

    expect(find.text('待复习 1 张'), findsOneWidget);
    expect(find.text('review'), findsOneWidget);
    await tester.tap(find.text('显示释义'));
    await tester.pumpAndSettle();
    expect(find.text('词典摘要'), findsOneWidget);
    expect(find.text('再来一次'), findsOneWidget);
  });
}

final class _AvailableDictionaryEngine implements DictionaryEngine {
  const _AvailableDictionaryEngine();

  @override
  void clearActiveDictionary() {}

  @override
  Future<void> ensureIndex({required String mdxPath}) async {}

  @override
  Future<String> importMdx({required String mdxPath, String? mddPath}) async =>
      'Test Dictionary';

  @override
  Future<List<Article>> lookup(String query, {String? mdxPath}) async =>
      const [];

  @override
  Future<DictionaryResourceData?> readResource(
    String resourcePath, {
    required int maxBytes,
    String? mdxPath,
  }) async =>
      null;

  @override
  Future<List<String>> suggest(
    String prefix, {
    required int limit,
    String? mdxPath,
  }) async =>
      const [];
}

final class _RecordingDictionaryEngine implements DictionaryEngine {
  final List<String> importedPaths = [];
  final List<String> lookedUpPaths = [];
  int? firstLookupImportCount;

  @override
  void clearActiveDictionary() {}

  @override
  Future<void> ensureIndex({required String mdxPath}) async {}

  @override
  Future<String> importMdx({required String mdxPath, String? mddPath}) async {
    importedPaths.add(mdxPath);
    return File(mdxPath).uri.pathSegments.last;
  }

  @override
  Future<List<Article>> lookup(String query, {String? mdxPath}) async {
    firstLookupImportCount ??= importedPaths.length;
    if (mdxPath != null) lookedUpPaths.add(mdxPath);
    return const [];
  }

  @override
  Future<DictionaryResourceData?> readResource(
    String resourcePath, {
    required int maxBytes,
    String? mdxPath,
  }) async =>
      null;

  @override
  Future<List<String>> suggest(
    String prefix, {
    required int limit,
    String? mdxPath,
  }) async =>
      const [];
}
