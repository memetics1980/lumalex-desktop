import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/dictionary_group.dart';
import 'package:local_dictionary/models/dictionary_library_entry.dart';
import 'package:local_dictionary/screens/home_page.dart';

DictionaryLibraryEntry _entry(
  String title,
  String path, {
  String? groupId,
}) =>
    DictionaryLibraryEntry(
      title: title,
      mdxPath: path,
      importedAtMilliseconds: 1,
      groupId: groupId,
    );

void main() {
  const learners = DictionaryGroup(
    id: 'learners',
    name: '学习词典',
    sortOrder: 0,
  );
  const thesaurus = DictionaryGroup(
    id: 'thesaurus',
    name: '同义词典',
    sortOrder: 1,
  );

  test('screen lookup dictionaries follow group order', () {
    final ordered = screenLookupEntriesInGroupOrder(
      [
        _entry('未分组', 'u.mdx'),
        _entry('同义词', 't.mdx', groupId: 'thesaurus'),
        _entry('朗文', 'l.mdx', groupId: 'learners'),
        _entry('遗留分组', 'legacy.mdx', groupId: 'removed'),
      ],
      [learners, thesaurus],
    );

    expect(
      ordered.map((entry) => entry.title),
      ['朗文', '同义词', '未分组', '遗留分组'],
    );
  });

  test('screen lookup select renders grouped and escaped options', () {
    final entries = screenLookupEntriesInGroupOrder(
      [
        _entry('Oxford & Longman', 'l.mdx', groupId: 'learners'),
        _entry('Roget', 't.mdx', groupId: 'thesaurus'),
        _entry('其他', 'u.mdx'),
      ],
      [learners, thesaurus],
    );
    final html = buildScreenLookupDictionaryOptions(
      entries: entries,
      groups: [learners, thesaurus],
      selectedIndex: 1,
    );

    expect(html, contains('<optgroup label="学习词典 · 1 本">'));
    expect(html, contains('<optgroup label="同义词典 · 1 本">'));
    expect(html, contains('<optgroup label="未分组 · 1 本">'));
    expect(html, contains('Oxford &amp; Longman'));
    expect(html, contains('<option value="1" selected>Roget</option>'));
  });

  test('screen lookup menu renders scrollable group choices in index order',
      () {
    final entries = screenLookupEntriesInGroupOrder(
      [
        _entry('Oxford & Longman', 'l.mdx', groupId: 'learners'),
        _entry('<Roget>', 't.mdx', groupId: 'thesaurus'),
        _entry('其他', 'u.mdx'),
      ],
      [learners, thesaurus],
    );
    final html = buildScreenLookupDictionaryMenu(
      entries: entries,
      groups: [learners, thesaurus],
      selectedIndex: 1,
      scopeId: 'thesaurus',
    );

    expect(html, contains('onclick="lumalexSelectScope(-1)"'));
    expect(html, contains('onclick="lumalexSelectScope(0)"'));
    expect(html, contains('onclick="lumalexSelectScope(1)"'));
    expect(html, contains('onclick="lumalexSelectScope(-2)"'));
    expect(html, contains('学习词典 · 1 本'));
    expect(html, contains('同义词典 · 1 本'));
    expect(html, contains('未分组 · 1 本'));
    expect(html, contains('Oxford &amp; Longman'));
    expect(html, contains('&lt;Roget&gt;'));
    expect(
        html, contains('data-index="1" onclick="lumalexSelectDictionary(1)"'));
    expect(html, contains('aria-selected="true"'));
    expect(html, contains('aria-pressed="true"'));
  });

  test('screen lookup scope limits search and arrows to its dictionaries', () {
    final entries = screenLookupEntriesInGroupOrder(
      [
        _entry('无分组', 'u.mdx'),
        _entry('同义', 't.mdx', groupId: 'thesaurus'),
        _entry('朗文', 'l.mdx', groupId: 'learners'),
        _entry('牛津', 'o.mdx', groupId: 'learners'),
        _entry('旧分组', 'old.mdx', groupId: 'deleted'),
      ],
      [learners, thesaurus],
    );

    expect(
      screenLookupIndexesForScope(entries, [learners, thesaurus], 'learners'),
      [0, 1],
    );
    expect(
      screenLookupIndexesForScope(
          entries, [learners, thesaurus], DictionaryGroupScope.ungrouped),
      [3, 4],
    );
    expect(
      screenLookupIndexesForScope(
          entries, [learners, thesaurus], DictionaryGroupScope.all),
      [0, 1, 2, 3, 4],
    );
  });
}
