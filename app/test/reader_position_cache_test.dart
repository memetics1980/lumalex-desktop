import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/reader_position_cache.dart';

void main() {
  test('positions are isolated by normalized query and dictionary', () {
    final cache = ReaderPositionCache();
    cache.put('a.mdx', ' Signal ', 120);
    cache.put('b.mdx', 'signal', 340);

    expect(cache.get('a.mdx', 'signal'), 120);
    expect(cache.get('b.mdx', 'SIGNAL'), 340);
  });

  test('position cache evicts the least recently used location', () {
    final cache = ReaderPositionCache(maximumEntries: 2);
    cache.put('a.mdx', 'one', 10);
    cache.put('b.mdx', 'one', 20);
    expect(cache.get('a.mdx', 'one'), 10);
    cache.put('c.mdx', 'one', 30);

    expect(cache.get('a.mdx', 'one'), 10);
    expect(cache.get('b.mdx', 'one'), isNull);
    expect(cache.get('c.mdx', 'one'), 30);
  });

  test('removing a dictionary clears all of its saved positions', () {
    final cache = ReaderPositionCache();
    cache.put('a.mdx', 'one', 10);
    cache.put('a.mdx', 'two', 20);
    cache.put('b.mdx', 'one', 30);
    cache.removeDictionary('a.mdx');

    expect(cache.get('a.mdx', 'one'), isNull);
    expect(cache.get('a.mdx', 'two'), isNull);
    expect(cache.get('b.mdx', 'one'), 30);
  });

  test('clearing removes positions made stale by text reflow', () {
    final cache = ReaderPositionCache()..put('a.mdx', 'one', 10);
    cache.clear();

    expect(cache.get('a.mdx', 'one'), isNull);
  });
}
