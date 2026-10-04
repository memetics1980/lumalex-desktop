import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/retained_reader_order.dart';

void main() {
  test('LRU changes never reorder retained platform-view children', () {
    const libraryOrder = ['a.mdx', 'b.mdx', 'c.mdx'];

    final before = retainedReaderDisplayOrder(
      libraryPaths: libraryOrder,
      retainedLruPaths: const ['a.mdx', 'b.mdx'],
      selectedPath: 'b.mdx',
    );
    final after = retainedReaderDisplayOrder(
      libraryPaths: libraryOrder,
      retainedLruPaths: const ['b.mdx', 'a.mdx'],
      selectedPath: 'a.mdx',
    );

    expect(before, const ['a.mdx', 'b.mdx']);
    expect(after, before);
  });

  test('selected reader is included without disturbing library order', () {
    final paths = retainedReaderDisplayOrder(
      libraryPaths: const ['a.mdx', 'b.mdx', 'c.mdx'],
      retainedLruPaths: const ['a.mdx'],
      selectedPath: 'c.mdx',
    );

    expect(paths, const ['a.mdx', 'c.mdx']);
  });

  test('memory-pressure trimming always preserves the selected reader', () {
    expect(
      trimRetainedReaderLru(
        retainedLruPaths: const ['a.mdx', 'b.mdx', 'c.mdx'],
        selectedPath: 'a.mdx',
        maximumReaders: 1,
      ),
      const ['a.mdx'],
    );
    expect(
      trimRetainedReaderLru(
        retainedLruPaths: const ['a.mdx', 'b.mdx', 'c.mdx'],
        selectedPath: 'b.mdx',
        maximumReaders: 2,
      ),
      const ['c.mdx', 'b.mdx'],
    );
  });
}
