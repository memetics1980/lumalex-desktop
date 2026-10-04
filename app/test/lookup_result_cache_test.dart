import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/article.dart';
import 'package:local_dictionary/models/lookup_result_cache.dart';

void main() {
  const article = Article(
    dictionaryName: 'Test',
    mdxPath: '/test.mdx',
    headword: 'word',
    html: '<p>word</p>',
  );

  test('lookup cache is case insensitive', () {
    final cache = LookupResultCache();
    cache.put('/test.mdx', 'Word', const [article]);

    expect(cache.get('/test.mdx', 'word'), const [article]);
  });

  test('lookup cache evicts the least recently used entry', () {
    final cache = LookupResultCache(maximumEntries: 1);
    cache.put('/test.mdx', 'first', const [article]);
    cache.put('/test.mdx', 'second', const []);

    expect(cache.get('/test.mdx', 'first'), isNull);
    expect(cache.get('/test.mdx', 'second'), isEmpty);
  });

  test('lookup cache evicts large article HTML by byte budget', () {
    final cache = LookupResultCache(maximumEntries: 8, maximumBytes: 30);
    const largeArticle = Article(
      dictionaryName: 'Test',
      mdxPath: '/test.mdx',
      headword: 'large',
      html: '12345678901',
    );

    cache.put('/test.mdx', 'small', const [article]);
    cache.put('/test.mdx', 'large', const [largeArticle]);

    expect(cache.get('/test.mdx', 'small'), isNull);
    expect(cache.get('/test.mdx', 'large'), const [largeArticle]);
  });

  test('removes every cached query for one replaced dictionary', () {
    final cache = LookupResultCache();
    cache.put('/test.mdx', 'first', const [article]);
    cache.put('/test.mdx', 'second', const [article]);
    cache.put('/other.mdx', 'first', const [article]);

    cache.removeDictionary('/test.mdx');

    expect(cache.get('/test.mdx', 'first'), isNull);
    expect(cache.get('/test.mdx', 'second'), isNull);
    expect(cache.get('/other.mdx', 'first'), const [article]);
  });
}
