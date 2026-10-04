import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dictionary_group.dart';

abstract interface class DictionaryGroupsStore {
  Future<DictionaryGroupSnapshot> load();

  Future<void> save(DictionaryGroupSnapshot snapshot);
}

class PreferencesDictionaryGroupsStore implements DictionaryGroupsStore {
  PreferencesDictionaryGroupsStore([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'local_dictionary.groups.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<DictionaryGroupSnapshot> load() async {
    final saved = await _preferences.getString(_key);
    if (saved == null || saved.isEmpty) {
      return const DictionaryGroupSnapshot();
    }
    try {
      return DictionaryGroupSnapshot.fromJson(jsonDecode(saved));
    } on FormatException {
      return const DictionaryGroupSnapshot();
    }
  }

  @override
  Future<void> save(DictionaryGroupSnapshot snapshot) =>
      _preferences.setString(_key, jsonEncode(snapshot.toJson()));
}

class InMemoryDictionaryGroupsStore implements DictionaryGroupsStore {
  DictionaryGroupSnapshot _snapshot = const DictionaryGroupSnapshot();

  @override
  Future<DictionaryGroupSnapshot> load() async => _snapshot;

  @override
  Future<void> save(DictionaryGroupSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}
