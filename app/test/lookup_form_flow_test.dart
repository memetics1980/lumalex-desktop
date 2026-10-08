import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:local_dictionary/main.dart';
import 'package:local_dictionary/models/article.dart';
import 'package:local_dictionary/models/dictionary_library_entry.dart';
import 'package:local_dictionary/services/dictionary_engine.dart';
import 'package:local_dictionary/services/dictionary_content_server.dart';
import 'package:local_dictionary/services/dictionary_library.dart';
import 'package:local_dictionary/services/windows_app_settings.dart';
import 'package:local_dictionary/services/word_records.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

// Exercise the real main-window query and favorite actions without launching
// native WebView windows in a widget test. Popup documents are still read from
// the real loopback content server below.
class _TestWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
          PlatformInAppWebViewWidgetCreationParams params) =>
      _TestWebView(params);
  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _TestWebViewController();
}

class _TestWebView extends PlatformInAppWebViewWidget {
  _TestWebView(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      controller as T;
  @override
  void dispose() {}
}

class _TestWebViewController extends PlatformInAppWebViewController {
  _TestWebViewController()
      : super.implementation(
            const PlatformInAppWebViewControllerCreationParams(id: 0));
  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {}
  @override
  void dispose({bool isKeepAlive = false}) {}
}

Future<String> _readDocument(Uri uri) =>
    HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri))
            .close()
            .timeout(const Duration(seconds: 3));
        return await utf8.decoder.bind(response).join();
      } finally {
        client.close(force: true);
      }
    }, _LoopbackHttpOverrides());

final class _FormEngine implements DictionaryEngine {
  final Map<String, Map<String, String>> entries;
  final List<String> queries = [];
  _FormEngine(this.entries);
  @override
  Future<List<Article>> lookup(String query, {String? mdxPath}) async {
    queries.add(query);
    final html = entries[mdxPath]?[query];
    return html == null
        ? []
        : [
            Article(
                dictionaryName: 'Test',
                mdxPath: mdxPath!,
                headword: query,
                html: html)
          ];
  }

  @override
  Future<String> importMdx({required String mdxPath, String? mddPath}) async =>
      mdxPath;
  @override
  Future<void> ensureIndex({required String mdxPath}) async {}
  @override
  void clearActiveDictionary() {}
  @override
  Future<List<String>> suggest(String prefix,
          {required int limit, String? mdxPath}) async =>
      [];
  @override
  Future<DictionaryResourceData?> readResource(String resourcePath,
          {required int maxBytes, String? mdxPath}) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const speech = MethodChannel('local_dictionary/text_to_speech');
  setUp(() {
    InAppWebViewPlatform.instance = _TestWebViewPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speech, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(speech, null);
  });
  const channel = MethodChannel('local_dictionary/windows_screen_lookup');
  const lifecycle = MethodChannel('local_dictionary/windows_window_lifecycle');

  Future<void> emit(WidgetTester tester, String event,
      [Map<String, Object>? arguments]) async {
    final response = Completer<ByteData?>();
    await tester.runAsync(() async {
      tester.binding.channelBuffers.push(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(event, arguments)),
          response.complete);
    });
    for (var attempt = 0; !response.isCompleted && attempt < 150; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(response.isCompleted, isTrue,
        reason: 'Native event $event did not complete');
    final bytes = await response.future;
    if (bytes != null) channel.codec.decodeEnvelope(bytes);
    await tester.pump();
  }

  for (final mode in [
    'coughed up',
    'exciting',
    'excited',
    'root',
    'exactAdjective',
    'resulting',
    'suckling',
    'sucklingAi',
    'sucklingAiMissing'
  ]) {
    final query = mode == 'root'
        ? 'coughed up'
        : mode == 'exactAdjective'
            ? 'exciting'
            : mode.startsWith('suckling')
                ? 'suckling'
                : mode;
    testWidgets(
        'popup $mode preserves the original selection and resolution kind',
        (tester) async {
      final temp = Directory.systemTemp.createTempSync('lumalex-forms-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final library = InMemoryDictionaryLibrary();
      final path = '${temp.path}/test.mdx';
      File(path).writeAsBytesSync([0]);
      await library.upsert(DictionaryLibraryEntry(
          title: 'Test', mdxPath: path, importedAtMilliseconds: 1));
      final engine = _FormEngine({
        path: {
          if (mode != 'root') 'cough up': '<p>PHRASE_DEFINITION</p>',
          'cough': '<p>HEADWORD_DEFINITION</p>',
          'excite': '<p>RELATED_VERB_DEFINITION</p>',
          if (mode == 'resulting') 'resulting': '<p>ORIGINAL_RESULTING</p>',
          if (mode == 'resulting') 'result': '<p>RESULT_BASE_ENTRY</p>',
          if (query == 'suckling') 'suckling': '<p>NOUN_DEFINITION</p>',
          if (query == 'suckling' && mode != 'sucklingAiMissing')
            'suckle': '<p>SUCKLE_VERB_DEFINITION</p>',
        }
      });
      if (mode == 'exactAdjective') {
        final secondPath = '${temp.path}/second.mdx';
        File(secondPath).writeAsBytesSync([0]);
        await library.upsert(DictionaryLibraryEntry(
            title: 'Second', mdxPath: secondPath, importedAtMilliseconds: 2));
        engine.entries[secondPath] = {
          'exciting': '<p>ADJECTIVE_DEFINITION</p>'
        };
      }
      final documents = <Uri>[];
      final displayQueries = <String>[];
      final records = InMemoryWordRecordsStore();
      final aiMode = mode.contains('Ai');
      final aiRequests = <Map<String, dynamic>>[];
      final aiPayloads = <Map<String, dynamic>>[];
      final server = aiMode
          ? await tester
              .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0))
          : null;
      if (server != null) {
        await tester.runAsync(() async {
          server.listen((request) async {
            aiRequests.add(jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>);
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'lemma': 'suckle',
                      'partOfSpeech': 'verb',
                      'englishMeaning': 'to take milk',
                      'chineseMeaning': '吃奶',
                      'evidence': 'also suckling',
                      'confidence': 'high',
                      'ambiguityNote': ''
                    })
                  }
                }
              ]
            }));
            await request.response.close();
          });
        });
        addTearDown(() => server.close(force: true));
      }
      await tester.runAsync(() => DictionaryContentServer.instance.prewarm());
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycle, (_) async => null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        if (call.method == 'loadAiApiKey') return aiMode ? 'test-key' : '';
        if (call.method == 'updateAiResult') {
          aiPayloads.add(jsonDecode(utf8.decode(
                  base64Decode((call.arguments as Map)['payload'] as String)))
              as Map<String, dynamic>);
        }
        if (call.method == 'showArticle') {
          displayQueries.add((call.arguments as Map)['query'] as String);
          final uri = Uri.parse((call.arguments as Map)['uri'] as String);
          expect(uri.host, '127.0.0.1');
          documents.add(uri);
        }
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(lifecycle, null);
      });
      await HttpOverrides.runWithHttpOverrides(
          () => tester.pumpWidget(DictionaryApp(
              engine: engine,
              library: library,
              wordRecords: records,
              windowsAppSettings: InMemoryWindowsAppSettingsStore(
                  screenLookupAiEnabled: aiMode,
                  screenLookupAiModel: 'test-model',
                  screenLookupAiBaseUrl: server == null
                      ? 'https://example.com/v1'
                      : 'http://127.0.0.1:${server.port}/v1'))),
          _LoopbackHttpOverrides());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      await emit(tester, 'lookupRequested', {
        'text': query,
        'context': 'An exciting trip; China has coughed up fossils.',
        'x': 100,
        'y': 100,
        'usedClipboardFallback': false,
      });
      expect(documents, isNotEmpty);
      expect(documents.last.path, contains('article'));
      var document =
          (await tester.runAsync(() => _readDocument(documents.last)))!;
      expect(document, contains('<strong>$query</strong>'));
      expect(document, isNot(contains('lumalex-lookup-form-notice')));
      expect(document, isNot(contains('lumalex-lookup-form-help')));
      expect(document, isNot(contains('正在查看相关原形')));
      if (aiMode) {
        expect(aiRequests, isEmpty);
        if (mode != 'sucklingAiMissing') {
          await emit(tester, 'selectLookupForm', {'index': 0});
        }
        await emit(tester, 'analyzeAi');
        expect(aiPayloads.last['status'], 'success');
        expect(aiRequests.single['messages'].last['content'],
            contains('suckling'));
        expect(
            jsonDecode(aiRequests.single['messages'].last['content'] as String)[
                'selectedWord'],
            'suckling');
        expect(aiRequests.single['messages'].last['content'],
            contains('An exciting trip'));
        expect(aiPayloads.last['dictionaryLemma'],
            mode == 'sucklingAiMissing' ? isNull : 'suckle');
        if (mode != 'sucklingAiMissing') {
          await emit(tester, 'selectLookupForm', {'index': -1});
          await emit(tester, 'viewAiLemma');
          document =
              (await tester.runAsync(() => _readDocument(documents.last)))!;
          expect(document, contains('SUCKLE_VERB_DEFINITION'));
          expect(document, contains('<strong>suckle</strong>'));
          expect(displayQueries.last, 'suckle');
        }
      } else if (mode == 'exactAdjective') {
        expect(document, contains('ADJECTIVE_DEFINITION'));
        expect(document, isNot(contains('id="lumalex-lookup-form-notice"')));
        expect(document, contains('相关原形 excite'));
        expect(document, isNot(contains('RELATED_VERB_DEFINITION')));
        await emit(tester, 'selectDictionary', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, isNot(contains('RELATED_VERB_DEFINITION')));
        await emit(tester, 'selectLookupForm', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('RELATED_VERB_DEFINITION'));
        expect(document, contains('<strong>excite</strong>'));
        await emit(tester, 'selectLookupForm', {'index': -1});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('ADJECTIVE_DEFINITION'));
        expect(document, isNot(contains('RELATED_VERB_DEFINITION')));
      } else if (mode == 'resulting') {
        expect(document, contains('ORIGINAL_RESULTING'));
        await emit(tester, 'selectLookupForm', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('RESULT_BASE_ENTRY'));
        expect(document, contains('原词 resulting'));
        expect(document, contains('相关原形 result'));
        expect(RegExp('词形并存').allMatches(document).length, 1);
        for (final removed in [
          '原选词',
          '正在查看相关原形',
          '请结合原句判断词性',
          'lumalex-lookup-form-notice',
          'lumalex-lookup-form-help'
        ]) {
          expect(document, isNot(contains(removed)));
        }
        await emit(tester, 'selectLookupForm', {'index': -1});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('ORIGINAL_RESULTING'));
      } else if (mode == 'suckling') {
        expect(document, contains('NOUN_DEFINITION'));
        expect(document, contains('相关原形 suckle'));
        expect(document, isNot(contains('SUCKLE_VERB_DEFINITION')));
        await emit(tester, 'selectLookupForm', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('SUCKLE_VERB_DEFINITION'));
        expect(document, contains('<strong>suckle</strong>'));
        expect(document, contains('原词 suckling'));
        expect(displayQueries.last, 'suckle');
        await emit(tester, 'toggleFavorite');
        expect(await records.loadFavorites(), ['suckle']);
        expect((await records.loadReviewCards()).single.gloss,
            'SUCKLE_VERB_DEFINITION');
        expect(document, contains('词形并存，不代表本句词性'));
        expect(document, isNot(contains('原选词')));
        expect(document, isNot(contains('正在查看相关原形')));
        await emit(tester, 'selectLookupForm', {'index': -1});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('NOUN_DEFINITION'));
        expect(document, isNot(contains('SUCKLE_VERB_DEFINITION')));
        expect(document, contains('<strong>suckling</strong>'));
        expect(document, contains('class="lumalex-screen-favorite"'));
        await emit(tester, 'selectLookupForm', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('class="lumalex-screen-favorite active"'));
        await emit(tester, 'selectDictionaryScope', {'scopeCode': -2});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('<strong>suckle</strong>'));
        expect(displayQueries.last, 'suckle');
        await emit(tester, 'toggleFavorite');
        expect(await records.loadFavorites(), isEmpty);
        await emit(tester, 'selectLookupForm', {'index': -1});
      } else if (mode == 'root') {
        expect(document, contains('查看主词 cough'));
        expect(document, isNot(contains('HEADWORD_DEFINITION')));
        await emit(tester, 'selectLookupForm', {'index': 0});
        document =
            (await tester.runAsync(() => _readDocument(documents.last)))!;
        expect(document, contains('HEADWORD_DEFINITION'));
        expect(document, contains('<strong>cough</strong>'));
      } else {
        expect(document, contains('词形并存，不代表本句词性'));
        expect(
            document,
            contains(query == 'coughed up'
                ? 'PHRASE_DEFINITION'
                : 'RELATED_VERB_DEFINITION'));
      }
      expect(engine.queries.first, query);
      if (mode != 'exactAdjective' &&
          mode != 'resulting' &&
          query != 'suckling') {
        expect(
            engine.queries,
            contains(mode == 'root'
                ? 'cough'
                : query == 'coughed up'
                    ? 'cough up'
                    : 'excite'));
      }
      await emit(tester, 'toggleFavorite');
      final favoriteQuery = mode == 'root'
          ? 'cough'
          : mode == 'sucklingAi'
              ? 'suckle'
              : query;
      expect(await records.loadFavorites(), [favoriteQuery]);
      if (mode == 'root') {
        // Native openMain receives the current query supplied by showArticle.
        await emit(tester, 'openInMain', {'text': displayQueries.last});
        expect(
            tester.widget<SearchBar>(find.byType(SearchBar)).controller!.text,
            'cough');
      }
      await emit(tester, 'screenLookupClosed');
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: !Platform.isWindows);
  }

  testWidgets('main form switching updates query, favorites and saved gloss',
      (tester) async {
    final temp =
        Directory.systemTemp.createTempSync('lumalex-main-active-form-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/test.mdx';
    File(path).writeAsBytesSync([0]);
    final library = InMemoryDictionaryLibrary();
    await library.upsert(DictionaryLibraryEntry(
        title: 'Test', mdxPath: path, importedAtMilliseconds: 1));
    final records = InMemoryWordRecordsStore();
    final engine = _FormEngine({
      path: {
        'suckling': '<p>NOUN_DEFINITION</p>',
        'suckle': '<p>SUCKLE_VERB_DEFINITION</p>'
      }
    });
    await tester.runAsync(() => DictionaryContentServer.instance.prewarm());
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(lifecycle, (_) async => null);
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycle, null);
    });
    await tester.pumpWidget(DictionaryApp(
        engine: engine,
        library: library,
        wordRecords: records,
        initialQuery: 'suckling'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, '原词 suckling'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '相关原形 suckle'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(tester.widget<SearchBar>(find.byType(SearchBar)).controller!.text,
        'suckle');
    expect(find.widgetWithText(ChoiceChip, '原词 suckling'), findsOneWidget);
    await tester.tap(find.byTooltip('收藏单词').last);
    await tester.pump();
    expect(await records.loadFavorites(), ['suckle']);
    expect((await records.loadReviewCards()).single.gloss,
        'SUCKLE_VERB_DEFINITION');
    expect(await records.loadHistory(), contains('suckle'));
    await tester.tap(find.widgetWithText(ChoiceChip, '原词 suckling'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(tester.widget<SearchBar>(find.byType(SearchBar)).controller!.text,
        'suckling');
    await tester.tap(find.byTooltip('收藏单词').last);
    await tester.pump();
    expect(await records.loadFavorites(), ['suckling', 'suckle']);
    expect(
        (await records.loadReviewCards())
            .firstWhere((card) => card.word == 'suckling')
            .gloss,
        'NOUN_DEFINITION');
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets(
      'main window retains original query and persistent related-form notice',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('lumalex-main-forms-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/test.mdx';
    File(path).writeAsBytesSync([0]);
    final library = InMemoryDictionaryLibrary();
    await library.upsert(DictionaryLibraryEntry(
        title: 'Test', mdxPath: path, importedAtMilliseconds: 1));
    final records = InMemoryWordRecordsStore();
    final engine = _FormEngine({
      path: {'cough': '<p>HEADWORD_DEFINITION</p>'}
    });
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(lifecycle, (_) async => null);
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(lifecycle, null);
    });
    await tester.pumpWidget(DictionaryApp(
        engine: engine,
        library: library,
        wordRecords: records,
        initialQuery: 'coughed up'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lookup-related-form-notice')),
        findsOneWidget);
    expect(find.text('查看主词 cough'), findsOneWidget);
    final search = tester.widget<SearchBar>(find.byType(SearchBar));
    expect(search.controller!.text, 'coughed up');
    expect(await records.loadHistory(), contains('coughed up'));
    expect(await records.loadHistory(), isNot(contains('cough')));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('lookup-related-form-notice')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);
}
