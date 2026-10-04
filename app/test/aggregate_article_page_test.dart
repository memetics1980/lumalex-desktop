import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/screens/aggregate_article_page.dart';

void main() {
  test('selected-dictionary presentation shows only the active section', () {
    final css = aggregateArticlePresentationCss(
      AggregateArticlePresentation.selectedDictionary,
    );

    expect(
      css,
      contains('body.selected-dictionary .dictionary-section { display: none'),
    );
    expect(css, contains('.dictionary-section.active { display: block'));
    expect(css, contains('.dictionary-header { display: none'));
  });

  test('dictionary tab switching preserves scroll without animation', () {
    final javascript = aggregateDictionarySelectionJavascript();

    expect(javascript, contains('dictionaryScrollOffsets.set(current.id'));
    expect(javascript, contains("current.classList.remove('active')"));
    expect(javascript, contains("next.classList.add('active')"));
    expect(javascript, contains("behavior: 'auto'"));
    expect(javascript, isNot(contains("behavior: 'smooth'")));
  });

  test('continuous presentation adds no tab-only hiding rules', () {
    expect(
      aggregateArticlePresentationCss(
        AggregateArticlePresentation.continuous,
      ),
      isEmpty,
    );
  });

  test('iframe selection is forwarded with its dictionary token', () {
    final javascript = aggregateDictionarySelectionObserverJavascript();

    expect(javascript, contains("String(doc.getSelection() || '').trim()"));
    expect(
      javascript,
      contains("bridge.callHandler('aggregateDictionarySelection', token"),
    );
    expect(javascript, contains("doc.addEventListener('selectionchange'"));
    expect(javascript, contains("doc.addEventListener('contextmenu'"));
  });

  test('Windows iframe menu dispatches touch-sized Copy and Lookup actions',
      () {
    final javascript = aggregateWindowsSelectionContextMenuJavascript();

    expect(javascript, contains("makeLumalexSelectionButton('复制', 'copy'"));
    expect(
      javascript,
      contains("makeLumalexSelectionButton('查词', 'lookup'"),
    );
    expect(javascript, contains("'min-height:44px'"));
    expect(
      javascript,
      contains("'aggregateDictionarySelectionAction', token, action"),
    );
    expect(javascript, contains('const dispatch = async (event) =>'));
    expect(
      javascript,
      contains("button.addEventListener('pointerdown', dispatch)"),
    );
    expect(javascript, contains('await bridge.callHandler('));
    expect(javascript, contains('finally {'));
    expect(
      javascript,
      contains("lookupUrl.searchParams.set('token', token)"),
    );
  });
}
