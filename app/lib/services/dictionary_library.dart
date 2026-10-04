import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/dictionary_library_entry.dart';

/// Persists only the local library index. Dictionary contents and MDD files
/// remain at their original user-selected locations.
abstract interface class DictionaryLibrary {
  Future<List<DictionaryLibraryEntry>> load();

  Future<List<DictionaryLibraryEntry>> upsert(DictionaryLibraryEntry entry);

  Future<List<DictionaryLibraryEntry>> remove(String mdxPath);

  Future<List<DictionaryLibraryEntry>> reorder(List<String> mdxPaths);

  /// Atomically replaces the library after a source refresh changes Android
  /// document URIs. Callers retain the existing display order explicitly.
  Future<List<DictionaryLibraryEntry>> replaceAll(
    List<DictionaryLibraryEntry> entries,
  );
}

abstract interface class DictionaryLibraryStorage {
  Future<String?> read();

  Future<void> write(String value);
}

class PreferencesDictionaryLibraryStorage implements DictionaryLibraryStorage {
  PreferencesDictionaryLibraryStorage([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'local_dictionary.library.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read() => _preferences.getString(_key);

  @override
  Future<void> write(String value) => _preferences.setString(_key, value);
}

class PersistentDictionaryLibrary implements DictionaryLibrary {
  PersistentDictionaryLibrary([DictionaryLibraryStorage? storage])
      : _storage = storage ?? PreferencesDictionaryLibraryStorage();

  final DictionaryLibraryStorage _storage;
  List<DictionaryLibraryEntry>? _entries;

  @override
  Future<List<DictionaryLibraryEntry>> load() async {
    final entries = await _ensureLoaded();
    return List.unmodifiable(entries);
  }

  @override
  Future<List<DictionaryLibraryEntry>> upsert(
      DictionaryLibraryEntry entry) async {
    final entries = await _ensureLoaded();
    final existingIndex = entries.indexWhere(
      (existing) => existing.mdxPath == entry.mdxPath,
    );
    if (existingIndex < 0) {
      entries.add(entry);
    } else {
      entries[existingIndex] = entry;
    }
    await _save(entries);
    return List.unmodifiable(entries);
  }

  @override
  Future<List<DictionaryLibraryEntry>> remove(String mdxPath) async {
    final entries = await _ensureLoaded();
    entries.removeWhere((entry) => entry.mdxPath == mdxPath);
    await _save(entries);
    return List.unmodifiable(entries);
  }

  @override
  Future<List<DictionaryLibraryEntry>> reorder(List<String> mdxPaths) async {
    final entries = await _ensureLoaded();
    final byPath = {for (final entry in entries) entry.mdxPath: entry};
    final reordered = <DictionaryLibraryEntry>[];
    for (final path in mdxPaths) {
      final entry = byPath.remove(path);
      if (entry != null) {
        reordered.add(entry);
      }
    }
    reordered.addAll(
      entries.where((entry) => byPath.containsKey(entry.mdxPath)),
    );
    entries
      ..clear()
      ..addAll(reordered);
    await _save(entries);
    return List.unmodifiable(entries);
  }

  @override
  Future<List<DictionaryLibraryEntry>> replaceAll(
    List<DictionaryLibraryEntry> nextEntries,
  ) async {
    final entries = await _ensureLoaded();
    entries
      ..clear()
      ..addAll(nextEntries);
    await _save(entries);
    return List.unmodifiable(entries);
  }

  Future<List<DictionaryLibraryEntry>> _ensureLoaded() async {
    if (_entries case final entries?) {
      return entries;
    }

    final saved = await _storage.read();
    _entries = _decode(saved);
    return _entries!;
  }

  Future<void> _save(List<DictionaryLibraryEntry> entries) => _storage
      .write(jsonEncode(entries.map((entry) => entry.toJson()).toList()));

  List<DictionaryLibraryEntry> _decode(String? saved) {
    if (saved == null || saved.isEmpty) {
      return <DictionaryLibraryEntry>[];
    }

    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List<Object?>) {
        return <DictionaryLibraryEntry>[];
      }
      final entries = decoded
          .map(DictionaryLibraryEntry.fromJson)
          .whereType<DictionaryLibraryEntry>()
          .toList();
      return entries;
    } on FormatException {
      return <DictionaryLibraryEntry>[];
    }
  }
}

/// Keeps widget tests and previews independent from platform preference APIs.
class InMemoryDictionaryLibrary extends PersistentDictionaryLibrary {
  InMemoryDictionaryLibrary() : super(_MemoryDictionaryLibraryStorage());
}

class _MemoryDictionaryLibraryStorage implements DictionaryLibraryStorage {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async {
    _value = value;
  }
}
