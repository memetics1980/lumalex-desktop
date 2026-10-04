import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/search_fallback.dart';

void main() {
  group('morphological fallbacks', () {
    test('normalizes irregular and inflected words', () {
      expect(morphologicalFallbacks('went'), contains('go'));
      expect(morphologicalFallbacks('studies'), contains('study'));
      expect(morphologicalFallbacks('running'), contains('run'));
      expect(
          morphologicalFallbacks('responsibilities').first, 'responsibility');
      expect(morphologicalFallbacks('cats'), contains('cat'));
      expect(morphologicalFallbacks('healthier').first, 'healthy');
      expect(morphologicalFallbacks('healthiest').first, 'healthy');
      expect(morphologicalFallbacks('bigger').first, 'big');
      expect(morphologicalFallbacks('largest'), contains('large'));
      expect(morphologicalFallbacks("cat's").first, 'cat');
    });

    test('does not rewrite phrases or non-Latin queries', () {
      expect(morphologicalFallbacks('looked up'), isEmpty);
      expect(morphologicalFallbacks('测试'), isEmpty);
    });
  });

  test('spelling prefixes include a transposition repair', () {
    expect(spellingSearchPrefixes('recieve'), contains('receive'));
  });

  test('spelling candidates are ranked by edit distance', () {
    expect(
      rankSpellingCandidates(
        'recieve',
        const ['recipe', 'receive', 'receiver', 'relieve'],
      ).first,
      'receive',
    );
  });

  test('Levenshtein distance handles insertion and substitution', () {
    expect(levenshteinDistance('word', 'words'), 1);
    expect(levenshteinDistance('cat', 'cut'), 1);
  });
}
