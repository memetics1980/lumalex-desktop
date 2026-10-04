import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/dictionary_library_entry.dart';
import 'package:local_dictionary/services/dictionary_library.dart';

void main() {
  test('library replaces an existing path without changing its order',
      () async {
    final library = InMemoryDictionaryLibrary();
    final older = DictionaryLibraryEntry(
      title: 'Older',
      mdxPath: '/dictionaries/older.mdx',
      importedAtMilliseconds: 10,
    );
    final newer = DictionaryLibraryEntry(
      title: 'Newer',
      mdxPath: '/dictionaries/newer.mdx',
      importedAtMilliseconds: 20,
    );

    await library.upsert(older);
    await library.upsert(newer);
    final entries = await library.upsert(
      DictionaryLibraryEntry(
        title: 'Older renamed',
        mdxPath: older.mdxPath,
        importedAtMilliseconds: 30,
      ),
    );

    expect(entries.map((entry) => entry.title), ['Older renamed', 'Newer']);
  });

  test('library ignores malformed saved entries', () async {
    final storage = _Storage(
        '[{"title":"Valid","mdxPath":"/valid.mdx","importedAtMilliseconds":1},{"title":false}]');
    final library = PersistentDictionaryLibrary(storage);

    final entries = await library.load();

    expect(entries, hasLength(1));
    expect(entries.single.title, 'Valid');
    expect(entries.single.isEnabled, isTrue);
  });

  test('library persists enabled state and explicit order', () async {
    final library = InMemoryDictionaryLibrary();
    final first = DictionaryLibraryEntry(
      title: 'First',
      mdxPath: '/first.mdx',
      importedAtMilliseconds: 1,
    );
    final second = DictionaryLibraryEntry(
      title: 'Second',
      mdxPath: '/second.mdx',
      importedAtMilliseconds: 2,
      isEnabled: false,
    );
    await library.upsert(first);
    await library.upsert(second);

    final reordered = await library.reorder([second.mdxPath, first.mdxPath]);

    expect(reordered.map((entry) => entry.title), ['Second', 'First']);
    expect(reordered.first.isEnabled, isFalse);
  });

  test('custom display name keeps dictionary identity and settings', () async {
    final library = InMemoryDictionaryLibrary();
    final original = DictionaryLibraryEntry(
      title: 'Original package title',
      mdxPath: '/dictionaries/example.mdx',
      accessPath: '/dictionaries',
      importedAtMilliseconds: 42,
      isEnabled: false,
      groupId: 'group-english',
    );
    await library.upsert(original);

    final entries = await library.upsert(
      original.copyWith(title: 'My Oxford Dictionary'),
    );

    expect(entries.single.title, 'My Oxford Dictionary');
    expect(entries.single.mdxPath, original.mdxPath);
    expect(entries.single.accessPath, original.accessPath);
    expect(entries.single.importedAtMilliseconds, 42);
    expect(entries.single.isEnabled, isFalse);
    expect(entries.single.groupId, 'group-english');
  });

  test('group can be assigned and cleared without changing dictionary data',
      () async {
    final original = DictionaryLibraryEntry(
      title: 'Dictionary',
      mdxPath: '/dictionary.mdx',
      accessPath: '/dictionaries',
      importedAtMilliseconds: 42,
      groupId: 'group-english',
    );

    final cleared = original.copyWith(clearGroupId: true);

    expect(cleared.groupId, isNull);
    expect(cleared.title, original.title);
    expect(cleared.mdxPath, original.mdxPath);
    expect(cleared.accessPath, original.accessPath);
  });

  test('library restores Android MDD document URIs', () async {
    final source = DictionaryLibraryEntry(
      title: 'Android dictionary',
      mdxPath: 'content://provider/document/dictionary.mdx',
      accessPath: 'content://provider/tree/dictionaries',
      sourceRelativePath: 'Oxford/example.mdx',
      sourceVersion: '1234:5678',
      contentFingerprint: 'sha256:abc123',
      mddPaths: const [
        'content://provider/document/dictionary.mdd',
        'content://provider/document/dictionary.1.mdd',
      ],
      sidecarResources: const [
        DictionarySidecarResource(
          uri: 'content://provider/document/styles/oald.css',
          relativePath: 'styles/oald.css',
        ),
      ],
      importedAtMilliseconds: 42,
    );
    final library = InMemoryDictionaryLibrary();

    await library.upsert(source);
    final reloaded = await library.load();

    expect(reloaded.single.mddPaths, source.mddPaths);
    expect(
      reloaded.single.sidecarResources.single.relativePath,
      'styles/oald.css',
    );
    expect(reloaded.single.accessPath, source.accessPath);
    expect(reloaded.single.sourceRelativePath, source.sourceRelativePath);
    expect(reloaded.single.sourceVersion, source.sourceVersion);
    expect(reloaded.single.contentFingerprint, source.contentFingerprint);
  });

  test('replaceAll preserves the supplied identity order atomically', () async {
    final library = InMemoryDictionaryLibrary();
    final first = DictionaryLibraryEntry(
      title: 'First',
      mdxPath: 'content://old/first.mdx',
      importedAtMilliseconds: 1,
    );
    final second = DictionaryLibraryEntry(
      title: 'Second',
      mdxPath: 'content://old/second.mdx',
      importedAtMilliseconds: 2,
    );
    await library.upsert(first);
    await library.upsert(second);

    final entries = await library.replaceAll([
      first.copyWith(mdxPath: 'content://fresh/first.mdx'),
      second,
    ]);

    expect(entries.map((entry) => entry.title), ['First', 'Second']);
    expect(entries.first.mdxPath, 'content://fresh/first.mdx');
  });
}

class _Storage implements DictionaryLibraryStorage {
  _Storage(this.value);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async {
    value = next;
  }
}
