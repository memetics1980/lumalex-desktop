import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/screens/article_page.dart';

void main() {
  test('web content recovery stops after repeated terminations', () {
    final limiter = WebContentRecoveryLimiter();
    final startedAt = DateTime(2026, 1, 1, 12);

    expect(limiter.registerTermination(startedAt), isTrue);
    expect(
      limiter.registerTermination(startedAt.add(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      limiter.registerTermination(startedAt.add(const Duration(seconds: 2))),
      isFalse,
    );
    expect(
      limiter.registerTermination(startedAt.add(const Duration(seconds: 32))),
      isTrue,
    );
  });

  test('safe article document uses the isolated local origin', () {
    final document = buildSafeArticleDocument('<img src="image.png">');

    expect(document, contains("script-src 'none'"));
    expect(document, contains("connect-src 'self'"));
    expect(document, contains("img-src 'self' data: blob:"));
    expect(
      document,
      contains(
        '<base href="http://127.0.0.1/dictionary/test-session/resource/">',
      ),
    );
    expect(document, contains('<img src="image.png">'));
    expect(document, contains('.oald { display: block !important; }'));
    expect(
      document,
      contains(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      ),
    );
    // The host keeps the document isolated but does not overwrite publisher
    // spacing: MDX CSS remains the authority for its default mobile layout.
    expect(document, isNot(contains('padding: clamp(12px, 2vw, 24px)')));
    expect(document, isNot(contains('margin: 0 !important;')));
    expect(document, contains('<body class="lumalex-article"'));
  });

  test('default text scale does not enumerate every dictionary element', () {
    final document = buildArticleDocument(
      '<p>definition</p>',
      localScriptCompatibilityEnabled: true,
    );

    final defaultScaleCheck = document.indexOf(
      'if (Math.abs(nextScale - 1) < 0.001) {',
    );
    final elementEnumeration = document.indexOf('const snapshots = [];');
    expect(defaultScaleCheck, greaterThanOrEqualTo(0));
    expect(elementEnumeration, greaterThan(defaultScaleCheck));
    expect(document, contains('releaseTrackedElements();'));
    expect(
      document,
      contains("querySelectorAll('[' + markerAttribute + ']')"),
    );
  });

  test('sound URLs preserve encoded hashes in MDD filenames', () {
    expect(
      soundResourcePathForTesting(
        Uri.parse('sound://_test%23_ams_10.mp3'),
      ),
      '_test#_ams_10.mp3',
    );
  });

  test('sound URLs support Oxford and publisher shorthand variants', () {
    expect(
      dictionarySoundResourcePath('sound://_decrease%23_gbs_1.mp3'),
      '_decrease#_gbs_1.mp3',
    );
    expect(
      dictionarySoundResourcePath('sound:decrease__us_3_rr.mp3'),
      'decrease__us_3_rr.mp3',
    );
    expect(
      dictionarySoundResourcePath('sound://?file=audio%2Fday.mp3'),
      'audio/day.mp3',
    );
  });

  test('compatibility mode supports ordinary local dictionary scripts', () {
    final document = buildArticleDocument(
      '<script src="oaldpe.js"></script>',
      localScriptCompatibilityEnabled: true,
    );

    expect(
      document,
      contains("script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:"),
    );
    expect(document, contains("connect-src 'self'"));
    expect(document, contains("frame-src 'none'"));
    expect(document, contains("form-action 'none'"));
    expect(document, contains('name="color-scheme" content="light only"'));
    expect(document, contains('id="dictionary-host-light-theme"'));
    expect(document, contains('id="dictionary-host-sound-bridge"'));
    expect(
      document,
      contains('id="dictionary-host-double-click-lookup"'),
    );
    expect(
      document,
      contains('id="dictionary-host-selection-bridge"'),
    );
    expect(document, contains("callHandler('lookupDictionaryWord', headword)"));
    expect(document, contains("'dictionaryReaderSelectionChanged'"));
    expect(document, contains("closest('[href]')"));
    expect(document, contains("callHandler('playDictionarySound', href)"));
    expect(document, contains("'example-audio-ai a.audio_uk'"));
    expect(document, contains("'example-audio-ai a.audio_us'"));
    expect(document, contains("'a.sound-ai'"));
    expect(document, contains("'a.sound.tts'"));
    expect(document, contains("'speakDictionaryExample'"));
    expect(document, contains("includes('(UK)') ? 'en-GB' : 'en-US'"));
    expect(
      document.indexOf('dictionary-host-light-theme'),
      lessThan(document.indexOf('oaldpe.js')),
    );
    expect(document, isNot(contains('.oald { display: block !important; }')));
  });

  test('double-click lookup accepts one bounded headword', () {
    expect(doubleClickLookupHeadwordForTesting('  test  '), 'test');
    expect(
        doubleClickLookupHeadwordForTesting("mother-in-law"), 'mother-in-law');
    expect(doubleClickLookupHeadwordForTesting('测试'), '测试');
    expect(doubleClickLookupHeadwordForTesting('change of heart'), isNull);
    expect(
      doubleClickLookupHeadwordForTesting(List.filled(129, 'x').join()),
      isNull,
    );
    expect(doubleClickLookupHeadwordForTesting(null), isNull);
  });

  test('selection bridge payload keeps text and selection geometry', () {
    final selection = dictionarySelectionForTesting([
      '  community  ',
      10,
      20,
      100,
      45,
      768,
      1024,
    ]);

    expect(selection?.text, 'community');
    expect(selection?.headword, 'community');
    expect(selection?.rect, const Rect.fromLTRB(10, 20, 100, 45));
    expect(selection?.viewport, const Size(768, 1024));
  });

  test('selection bridge allows phrases for copying but not lookup', () {
    final selection = dictionarySelectionForTesting([
      'farming community',
      10,
      20,
      180,
      45,
      768,
      1024,
    ]);

    expect(selection?.text, 'farming community');
    expect(selection?.headword, isNull);
    expect(dictionarySelectionForTesting(['', 0, 0, 0, 0, 1, 1]), isNull);
    expect(dictionarySelectionForTesting(['word', 0, 0]), isNull);
  });

  test('Windows article document owns a touch-sized Copy and Lookup menu', () {
    final document = buildArticleDocument(
      '<p>select this word</p>',
      localScriptCompatibilityEnabled: true,
      includeWindowsSelectionMenu: true,
    );

    expect(document, contains('dictionary-host-windows-selection-menu'));
    expect(document, contains("makeButton('复制', 'copy', selected)"));
    expect(document, contains("makeButton('查词', 'lookup', selected)"));
    expect(document, contains("'min-height:44px'"));
    expect(
      document,
      contains("'dictionaryReaderSelectionAction', action, selected"),
    );
    expect(document, contains('const dispatch = async (event) =>'));
    expect(
        document, contains("button.addEventListener('pointerdown', dispatch)"));
    expect(document, contains('await bridge.callHandler('));
    expect(document, contains('finally {'));
    expect(
      document,
      contains("'/__lumalex_selection_lookup__', window.location.href"),
    );
  });

  test('Windows lookup navigation preserves Unicode text and optional token',
      () {
    final request = windowsSelectionLookupRequestForTesting(
      'lumalex-selection://lookup?token=dict%3A1&text=%E5%AE%89%E5%85%A8',
    );

    expect(request?.text, '安全');
    expect(request?.token, 'dict:1');
    expect(
      windowsSelectionLookupRequestForTesting(
        'http://127.0.0.1:54871/__lumalex_selection_lookup__?text=surface',
      )?.text,
      'surface',
    );
    expect(
      windowsSelectionLookupRequestForTesting('entry://security'),
      isNull,
    );
  });

  test('Cambridge package defaults to translated expanded senses', () {
    final defaults = publisherPresentationDefaultsForTesting(
      '<link rel="stylesheet" href="cdepe.css">',
    );

    expect(defaults, contains("'CDEPE_showTranslation', '1'"));
    expect(defaults, contains("'CDEPE_unfoldSense', '1'"));
    expect(defaults, contains("'CDEPE_touchToTranslate', '0'"));
    expect(defaults, contains("'CDEPE_unfoldBox2', '0'"));
    expect(defaults, contains("'CDEPE_unfoldBox3', '0'"));
    expect(defaults, contains("'CDEPE_unfoldBox4', '0'"));
    expect(defaults, contains("'CDEPE_unfoldBox5', '0'"));
    expect(defaults, contains('suppressActiveNavigationToggle'));
    expect(
      defaults,
      contains("'.cdepe-nav > span, .cdepe-nav-dict > span'"),
    );
    expect(
      publisherPresentationDefaultsForTesting(
        '<link rel="stylesheet" href="another.css">',
      ),
      isEmpty,
    );
  });

  test('Merriam-Webster package uses the translated expanded policy', () {
    final defaults = publisherPresentationDefaultsForTesting(
      '<link rel="stylesheet" href="maldpe.css">',
    );

    expect(defaults, contains('id="dictionary-host-maldpe-defaults"'));
    expect(defaults, contains("'MALDPE_showTranslation', '1'"));
    expect(defaults, contains("'MALDPE_unfoldSense', '1'"));
    expect(defaults, contains("'MALDPE_touchToTranslate', '0'"));
    expect(defaults, contains("target.closest('.maldpe-nav > span')"));
  });

  test('uses the supplied loopback resource origin', () {
    final document = buildArticleDocument(
      '<script src="dictionary.js"></script>',
      localScriptCompatibilityEnabled: true,
      resourceBaseUrl:
          'http://127.0.0.1:43123/dictionary/random-token/resource/',
    );

    expect(
      document,
      contains(
        '<base href="http://127.0.0.1:43123/'
        'dictionary/random-token/resource/">',
      ),
    );
    expect(document, isNot(contains('https://')));
  });

  test('scales text and line height without zooming the page width', () {
    final document = buildArticleDocument(
      '<p>dictionary entry</p>',
      localScriptCompatibilityEnabled: true,
      textScale: 1.4,
    );

    expect(
      document,
      contains(
        '<html style="-webkit-text-size-adjust: none; '
        'text-size-adjust: none">',
      ),
    );
    expect(document, contains('window.__lumalexSetTextScale = setTextScale'));
    expect(document, contains('setTextScale(1.4);'));
    expect(document, contains("'font-size'"));
    expect(document, contains("'line-height'"));
    expect(document, contains('data-lumalex-text-scale-base'));
    expect(document, contains('data-lumalex-original-font-size'));
    expect(document, contains('restorePublisherStyles();'));
    expect(document, isNot(contains('originals: new WeakMap()')));
    expect(document, isNot(contains('zoom: 1.4')));
    expect(document, contains('html, body, body *'));
    expect(document, contains('text-size-adjust: none !important'));
    expect(document,
        isNot(contains("window.addEventListener(\n        'resize'")));
    expect(document, isNot(contains("attributeFilter: ['class'")));
  });

  test('Windows selection menu does not retrigger article text scaling', () {
    final document = buildArticleDocument(
      '<div class="synonyms"><a>specific</a>, <a>particular</a></div>',
      localScriptCompatibilityEnabled: true,
      includeWindowsSelectionMenu: true,
      textScale: 1.2,
    );

    expect(
      document,
      contains("menu.setAttribute('data-lumalex-host-ui', 'selection-menu')"),
    );
    expect(
      document,
      contains("const hostUiSelector = '[data-lumalex-host-ui]'"),
    );
    expect(document, contains('!element.closest(hostUiSelector)'));
    expect(document, contains('!belongsToHostUi(node)'));
  });

  test('Collins SYN transitions cannot become the next font-size baseline', () {
    final document = buildArticleDocument(
      '''
      <style>
        .synonym { font-size: .83em; }
        .synonym a.explain { font-size: inherit; transition: all 1s; }
      </style>
      <div class="synonym"><b>SYN</b>
        <a class="ref explain" href="entry://specific">specific</a>
      </div>
      ''',
      localScriptCompatibilityEnabled: true,
      textScale: 1.2,
    );

    expect(
      document,
      contains('html.lumalex-text-scale-updating body *'),
    );
    expect(document, contains('transition: none !important'));
    expect(document, contains('root.classList.add(updateClass)'));
    expect(document, contains('void document.body.offsetHeight'));
    expect(document, contains('root.classList.remove(updateClass)'));
  });

  test('initial text scale is installed in the document before it is shown',
      () {
    final document = buildArticleDocument(
      '<p>dictionary entry</p>',
      localScriptCompatibilityEnabled: true,
      textScale: 1.1,
    );

    // The reader keeps its loading cover up until load-stop has called this
    // bootstrap setter. That avoids displaying a 100% first frame before the
    // configured 110% text size is ready.
    expect(document, contains('setTextScale(1.1);'));
  });

  test('Longman content keeps the mobile viewport at its adaptive base size',
      () {
    final document = buildArticleDocument(
      '<link href="lm6.css" rel="stylesheet"><div class="lm6">word</div>',
      localScriptCompatibilityEnabled: true,
    );

    expect(
      document,
      contains(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      ),
    );
    expect(
      document,
      contains(
        '<html style="-webkit-text-size-adjust: none; '
        'text-size-adjust: none">',
      ),
    );
    expect(document, contains('setTextScale(1.0);'));
  });

  test('foreground health check detects missing publisher stylesheets', () {
    expect(
      dictionaryDocumentResourcesHealthyForTesting({
        'readyState': 'complete',
        'bodyTextLength': 120,
        'stylesheetCount': 2,
        'loadedStylesheetCount': 2,
      }),
      isTrue,
    );
    expect(
      dictionaryDocumentResourcesHealthyForTesting({
        'readyState': 'complete',
        'bodyTextLength': 120,
        'stylesheetCount': 2,
        'loadedStylesheetCount': 1,
      }),
      isFalse,
    );
    expect(
      dictionaryDocumentResourcesHealthyForTesting({
        'readyState': 'loading',
        'bodyTextLength': 120,
        'stylesheetCount': 0,
        'loadedStylesheetCount': 0,
      }),
      isFalse,
    );
  });

  test('permits only the fixed private article document', () {
    expect(
      isArticleDocumentUrlForTesting(Uri.parse('about:blank')),
      isTrue,
    );
    expect(
      isArticleDocumentUrlForTesting(Uri.parse('https://example.com/')),
      isFalse,
    );
    expect(
      isArticleDocumentUrlForTesting(
        Uri.parse('about:blank?untrusted=true'),
      ),
      isFalse,
    );
  });

  test('parses common MDX headword links and anchors', () {
    expect(
      dictionaryLinkForTesting('entry://change%20of%20heart#sense-2'),
      (headword: 'change of heart', anchor: 'sense-2'),
    );
    expect(
      dictionaryLinkForTesting('bword://To%20become%20different'),
      (headword: 'To become different', anchor: null),
    );
    expect(
      dictionaryLinkForTesting('x-dictionary:r:sea-change'),
      (headword: 'sea-change', anchor: null),
    );
  });

  test('recognizes same-document anchors after base URL resolution', () {
    expect(
      dictionaryLinkForTesting('entry://#change_2'),
      (headword: null, anchor: 'change_2'),
    );
    expect(
      dictionaryLinkForTesting('dictres://resource/#change_2'),
      (headword: null, anchor: 'change_2'),
    );
  });

  test('rejects external and resource links as dictionary navigation', () {
    expect(dictionaryLinkForTesting('https://example.com/change'), isNull);
    expect(dictionaryLinkForTesting('sound://change.mp3'), isNull);
    expect(dictionaryLinkForTesting('dictres://resource/icon.png'), isNull);
  });
}
