import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/lookup_form_match.dart';
import 'package:local_dictionary/models/lookup_form_notice.dart';
import 'package:local_dictionary/models/search_fallback.dart';

void main() {
  test('popup shows choices and one brief hint without verbose explanations',
      () {
    const form = LookupFormCandidate('fossilize', LookupFormKind.relatedWord);
    final html = buildLookupFormChoicesHtml('fossilized', [form],
        selectedQuery: 'fossilize');
    expect(html, contains('原词 fossilized'));
    expect(html, contains('相关原形 fossilize'));
    expect(html, contains('词形并存，不代表本句词性；点击切换，或使用 AI 判断语境。'));
    expect(RegExp('词形并存').allMatches(html).length, 1);
    for (final removed in [
      '原选词',
      '正在查看相关原形',
      '请结合原句判断',
      'lumalex-lookup-form-notice',
      'lumalex-lookup-form-help',
      '<details',
      'ⓘ 词形说明'
    ]) {
      expect(html, isNot(contains(removed)));
    }
  });

  test('brief hint keeps the phrase headword an explicit choice', () {
    final html = buildLookupFormChoicesHtml('coughed up',
        [const LookupFormCandidate('cough', LookupFormKind.phraseHeadword)]);
    expect(html, contains('查看主词 cough'));
    expect(html, contains('词形并存'));
    expect(html, contains("postMessage('lookupForm:0')"));
    expect(html, isNot(contains('<details')));
  });

  test('related forms supplement independent nouns without replacing them',
      () async {
    for (final pair in [
      ('suckling', 'suckle'),
      ('meeting', 'meet'),
      ('building', 'build'),
      ('lying', 'lie')
    ]) {
      final forms = await collectRelatedLookupForms<String>(
          query: pair.$1,
          indexes: [2],
          isCurrent: () => true,
          lookup: (index, query) async {
            expect(index, 2);
            return query == pair.$2 ? ['verb'] : [];
          });
      expect(forms.map((match) => match.candidate!.query), [pair.$2]);
      expect(forms.single.values, ['verb']);
    }
  });

  test('supplements respect bounds, dictionary scope and cancellation',
      () async {
    final forms = await collectRelatedLookupForms<String>(
        query: 'suckling',
        indexes: [3],
        isCurrent: () => true,
        limit: 1,
        lookup: (index, query) async {
          expect(index, 3);
          return ['hit'];
        });
    expect(forms.length, 1);
    var current = true;
    final canceled = await collectRelatedLookupForms<String>(
        query: 'suckling',
        indexes: [3],
        isCurrent: () => current,
        lookup: (index, query) async {
          current = false;
          return ['hit'];
        });
    expect(canceled, isEmpty);
  });

  test('AI lemma is bounded plain text, never a URL or executable action', () {
    expect(validatedAiLemmaQuery(' Suckle ', 'suckling'), 'suckle');
    expect(validatedAiLemmaQuery('cough   up', 'coughed up'), 'cough up');
    for (final invalid in [
      'suckling',
      'https://example.com',
      "<script>",
      'a b c d e',
      ''
    ]) {
      expect(validatedAiLemmaQuery(invalid, 'suckling'), isNull);
    }
  });

  test('form choices preserve original and selected state with safe actions',
      () {
    final html = buildLookupFormChoicesHtml('<suckling&>',
        [const LookupFormCandidate('suckle', LookupFormKind.relatedWord)]);
    expect(html, contains('原词 &lt;suckling&amp;&gt;'));
    expect(html, contains('相关原形 suckle'));
    expect(html, contains("postMessage('lookupForm:-1')"));
    expect(html, contains("postMessage('lookupForm:0')"));
    expect(html, contains('aria-pressed="true"'));
    expect(buildLookupFormChoicesHtml('word', []), isEmpty);
  });

  test('phrase candidates preserve particles and handle irregular verbs', () {
    expect(lookupFormCandidates('coughed up').map((f) => f.query),
        contains('cough up'));
    expect(lookupFormCandidates('taking off').map((f) => f.query),
        contains('take off'));
    expect(lookupFormCandidates('gave up').map((f) => f.query),
        contains('give up'));
    expect(lookupFormCandidates('went through').map((f) => f.query),
        contains('go through'));
    expect(lookupFormCandidates('ran out of').map((f) => f.query),
        contains('run out of'));
    expect(lookupFormCandidates('working people'), isEmpty);
    expect(lookupFormCandidates('children in'), isEmpty);
    expect(lookupFormCandidates('这里的测试'), isEmpty);
    expect(lookupFormCandidates('this is a complete sentence'), isEmpty);
    expect(lookupFormCandidates('working out').length, lessThanOrEqualTo(4));
  });

  test('exact adjective in any scoped dictionary beats a preferred verb',
      () async {
    final calls = <String>[];
    final match = await resolveLookupForms<String>(
      query: 'exciting',
      indexes: [0, 1],
      isCurrent: () => true,
      lookup: (index, query) async {
        calls.add('$index:$query');
        if (index == 0 && query == 'excite') return ['verb'];
        if (index == 1 && query == 'exciting') return ['adjective'];
        return [];
      },
    );
    expect(match!.exact, isTrue);
    expect(match.index, 1);
    expect(match.values, ['adjective']);
    expect(calls, ['0:exciting', '1:exciting']);
  });

  test('missing adjective produces an explicitly related form, not a rewrite',
      () async {
    const original = 'excited';
    final match = await resolveLookupForms<String>(
      query: original,
      indexes: [0],
      isCurrent: () => true,
      lookup: (index, query) async => query == 'excite' ? ['verb'] : [],
    );
    expect(original, 'excited');
    expect(match!.candidate!.query, 'excite');
    expect(match.candidate!.kind, LookupFormKind.relatedWord);
    expect(match.candidate!.notice(original), contains('相关词形'));
    expect(match.candidate!.notice(original), contains('不代表本句词性或含义'));
  });

  test('phrase-base hit is displayed before a headword offer', () async {
    final match = await resolveLookupForms<String>(
      query: 'coughed up',
      indexes: [0, 1],
      isCurrent: () => true,
      lookup: (index, query) async => query == 'cough up'
          ? ['phrase']
          : query == 'cough'
              ? ['word']
              : [],
    );
    expect(match!.candidate!.query, 'cough up');
    expect(match.candidate!.kind, LookupFormKind.phraseBase);
    expect(match.candidate!.offerOnly, isFalse);
  });

  test('headword fallback is an offer, not a phrase definition', () async {
    final match = await resolveLookupForms<String>(
      query: 'coughed up',
      indexes: [0],
      isCurrent: () => true,
      lookup: (index, query) async => query == 'cough' ? ['word'] : [],
    );
    expect(match!.candidate!.query, 'cough');
    expect(match.candidate!.offerOnly, isTrue);
    final html = buildLookupFormChoicesHtml('coughed up', [match.candidate!]);
    expect(html, contains('查看主词 cough'));
    expect(match.candidate!.notice('coughed up'), contains('不等同于短语释义'));
    expect(html, contains("postMessage('lookupForm:0')"));
  });

  test('dictionary scope and cancellation are respected', () async {
    var current = true;
    final calls = <int>[];
    final match = await resolveLookupForms<String>(
      query: 'coughed up',
      indexes: [2],
      isCurrent: () => current,
      lookup: (index, query) async {
        calls.add(index);
        current = false;
        return [];
      },
    );
    expect(match, isNull);
    expect(calls, [2]);
  });

  test('HTML choices escape selected text and preserve the original query', () {
    final html = buildLookupFormChoicesHtml('<exciting&>',
        [const LookupFormCandidate('excite', LookupFormKind.relatedWord)]);
    expect(html, contains('&lt;exciting&amp;&gt;'));
    expect(html, isNot(contains('<exciting')));
    expect(isAmbiguousParticipialQuery('exciting'), isTrue);
    expect(isAmbiguousParticipialQuery('excited'), isTrue);
    expect(isAmbiguousParticipialQuery('red'), isFalse);
    expect(isAmbiguousParticipialQuery('recieve'), isFalse);
  });
}
