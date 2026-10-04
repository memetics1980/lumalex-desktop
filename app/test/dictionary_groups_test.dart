import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/dictionary_group.dart';
import 'package:local_dictionary/models/dictionary_library_entry.dart';
import 'package:local_dictionary/services/dictionary_groups.dart';

void main() {
  test('group snapshot restores stable order and active scope', () async {
    final store = InMemoryDictionaryGroupsStore();
    final snapshot = DictionaryGroupSnapshot(
      groups: const [
        DictionaryGroup(id: 'japanese', name: '日语', sortOrder: 2),
        DictionaryGroup(
          id: 'english',
          name: '英语',
          sortOrder: 1,
          colorIndex: 4,
        ),
      ],
      activeScopeId: 'english',
    );

    await store.save(snapshot);
    final restored = await store.load();

    expect(restored.activeScopeId, 'english');
    expect(restored.groups.map((group) => group.name), ['日语', '英语']);
    expect(restored.groups.last.colorIndex, 4);
  });

  test('decoded snapshot sorts groups and rejects a missing active group', () {
    final snapshot = DictionaryGroupSnapshot.fromJson(jsonDecode('''
      {
        "groups": [
          {"id":"japanese","name":"日语","sortOrder":2},
          {"id":"english","name":"英语","sortOrder":1}
        ],
        "activeScopeId":"missing"
      }
    '''));

    expect(snapshot.groups.map((group) => group.id), ['english', 'japanese']);
    expect(snapshot.activeScopeId, DictionaryGroupScope.all);
    expect(snapshot.groups.every((group) => group.colorIndex == 0), isTrue);
  });

  test('invalid group colors safely fall back to the first palette color', () {
    final group = DictionaryGroup.fromJson({
      'id': 'english',
      'name': '英语',
      'sortOrder': 0,
      'colorIndex': DictionaryGroup.colorChoiceCount,
    });

    expect(group, isNotNull);
    expect(group!.colorIndex, 0);
  });

  test('scope filtering distinguishes all, custom, and ungrouped', () {
    final entries = [
      const DictionaryLibraryEntry(
        title: 'English',
        mdxPath: '/english.mdx',
        importedAtMilliseconds: 1,
        groupId: 'english',
      ),
      const DictionaryLibraryEntry(
        title: 'Japanese',
        mdxPath: '/japanese.mdx',
        importedAtMilliseconds: 2,
        groupId: 'japanese',
      ),
      const DictionaryLibraryEntry(
        title: 'Ungrouped',
        mdxPath: '/ungrouped.mdx',
        importedAtMilliseconds: 3,
      ),
    ];

    expect(
      dictionaryEntriesForScope(entries, DictionaryGroupScope.all),
      hasLength(3),
    );
    expect(
      dictionaryEntriesForScope(entries, 'english').single.title,
      'English',
    );
    expect(
      dictionaryEntriesForScope(entries, DictionaryGroupScope.ungrouped)
          .single
          .title,
      'Ungrouped',
    );
  });
}
