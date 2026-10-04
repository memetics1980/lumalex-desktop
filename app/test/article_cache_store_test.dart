import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/article.dart';
import 'package:local_dictionary/services/article_cache_store.dart';

void main() {
  late Directory temporaryDirectory;
  late File sourceFile;
  late FileArticleCacheStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lumalex-article-cache-test-',
    );
    sourceFile = File('${temporaryDirectory.path}/dictionary.mdx');
    await sourceFile.writeAsString('source-v1');
    store = FileArticleCacheStore(
      Directory('${temporaryDirectory.path}/cache'),
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('persists positive and negative article results', () async {
    final article = Article(
      dictionaryName: 'Test dictionary',
      mdxPath: sourceFile.path,
      headword: 'test',
      html: '<p>definition</p>',
    );

    await store.write(sourceFile.path, 'Test', [article]);
    final restored = await store.read(sourceFile.path, 'test');
    expect(restored, hasLength(1));
    expect(restored!.single.dictionaryName, 'Test dictionary');
    expect(restored.single.headword, 'test');
    expect(restored.single.html, '<p>definition</p>');

    await store.write(sourceFile.path, 'missing', const []);
    expect(await store.read(sourceFile.path, 'MISSING'), isEmpty);
  });

  test('invalidates cached articles when the MDX source changes', () async {
    const article = Article(
      dictionaryName: 'Test dictionary',
      mdxPath: 'placeholder',
      headword: 'test',
      html: '<p>definition</p>',
    );
    await store.write(sourceFile.path, 'test', const [article]);

    await sourceFile.writeAsString('source-v2-is-larger');

    expect(await store.read(sourceFile.path, 'test'), isNull);
  });

  test('uses a seekable source path when the library id is a content URI',
      () async {
    const libraryId = 'content://documents/tree/dictionaries/document/oald.mdx';
    const article = Article(
      dictionaryName: 'Oxford',
      mdxPath: libraryId,
      headword: 'test',
      html: '<p>definition</p>',
    );

    await store.write(
      libraryId,
      'test',
      const [article],
      sourcePath: sourceFile.path,
    );

    final restored = await store.read(
      libraryId,
      'test',
      sourcePath: sourceFile.path,
    );
    expect(restored, hasLength(1));
    expect(restored!.single.mdxPath, libraryId);
  });
}
