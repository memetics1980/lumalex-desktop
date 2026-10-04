import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/review_card.dart';

List<String> addRecentWord(
  List<String> existing,
  String word, {
  int limit = 200,
}) {
  final normalized = word.trim();
  if (normalized.isEmpty || limit <= 0) {
    return List.of(existing.take(limit < 0 ? 0 : limit));
  }
  return [
    normalized,
    ...existing.where(
      (saved) => saved.toLowerCase() != normalized.toLowerCase(),
    ),
  ].take(limit).toList(growable: false);
}

List<String> toggleSavedWord(List<String> existing, String word) {
  final normalized = word.trim();
  if (normalized.isEmpty) {
    return List.of(existing);
  }
  final contains = existing.any(
    (saved) => saved.toLowerCase() == normalized.toLowerCase(),
  );
  return contains
      ? existing
          .where(
            (saved) => saved.toLowerCase() != normalized.toLowerCase(),
          )
          .toList(growable: false)
      : [normalized, ...existing];
}

List<String> removeSavedWords(
  List<String> existing,
  Iterable<String> words,
) {
  final removed = words
      .map((word) => word.trim().toLowerCase())
      .where((word) => word.isNotEmpty)
      .toSet();
  if (removed.isEmpty) {
    return List.of(existing);
  }
  return existing
      .where((word) => !removed.contains(word.trim().toLowerCase()))
      .toList(growable: false);
}

abstract interface class WordRecordsStore {
  Future<List<String>> loadHistory();

  Future<void> saveHistory(List<String> words);

  Future<List<String>> loadFavorites();

  Future<void> saveFavorites(List<String> words);

  Future<List<ReviewCard>> loadReviewCards();

  Future<void> saveReviewCards(List<ReviewCard> cards);

  /// The one reading scale shared by every enabled dictionary.
  Future<double> loadTextScale();

  Future<void> saveTextScale(double scale);
}

class PreferencesWordRecordsStore implements WordRecordsStore {
  PreferencesWordRecordsStore([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _historyKey = 'local_dictionary.history.v1';
  static const _favoritesKey = 'local_dictionary.favorites.v1';
  static const _reviewCardsKey = 'local_dictionary.review_cards.v1';
  static const _textScaleKey = 'local_dictionary.text_scale.v2';
  static const _legacyTextScalesKey = 'local_dictionary.text_scales.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<List<String>> loadHistory() => _read(_historyKey);

  @override
  Future<void> saveHistory(List<String> words) => _write(_historyKey, words);

  @override
  Future<List<String>> loadFavorites() => _read(_favoritesKey);

  @override
  Future<void> saveFavorites(List<String> words) =>
      _write(_favoritesKey, words);

  @override
  Future<List<ReviewCard>> loadReviewCards() async {
    final saved = await _preferences.getString(_reviewCardsKey);
    if (saved == null || saved.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List<Object?>) {
        return const [];
      }
      final cards = <ReviewCard>[];
      for (final value in decoded) {
        try {
          cards.add(ReviewCard.fromJson(value));
        } on FormatException {
          // A malformed legacy record should not make the whole wordbook
          // unreadable. Valid cards will still be retained.
        }
      }
      return cards;
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> saveReviewCards(List<ReviewCard> cards) =>
      _preferences.setString(
        _reviewCardsKey,
        jsonEncode(cards.map((card) => card.toJson()).toList(growable: false)),
      );

  @override
  Future<double> loadTextScale() async {
    final saved = await _preferences.getDouble(_textScaleKey);
    if (saved != null) {
      return _boundedTextScale(saved);
    }

    // Preserve a prior preference only when all dictionary-specific values
    // agreed. Different legacy values have no unambiguous global equivalent,
    // so the new global control starts at its 100% default in that case.
    final legacy = await _preferences.getString(_legacyTextScalesKey);
    if (legacy == null || legacy.isEmpty) return 1;
    try {
      final decoded = jsonDecode(legacy);
      if (decoded is! Map<String, Object?>) {
        return 1;
      }
      final scales = decoded.values
          .whereType<num>()
          .map((value) => _boundedTextScale(value.toDouble()))
          .toList(growable: false);
      if (scales.isEmpty || scales.any((scale) => scale != scales.first)) {
        return 1;
      }
      return scales.first;
    } on FormatException {
      return 1;
    }
  }

  @override
  Future<void> saveTextScale(double scale) =>
      _preferences.setDouble(_textScaleKey, _boundedTextScale(scale));

  Future<List<String>> _read(String key) async {
    final saved = await _preferences.getString(key);
    if (saved == null || saved.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List<Object?>) {
        return const [];
      }
      return decoded
          .whereType<String>()
          .map((word) => word.trim())
          .where((word) => word.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> _write(String key, List<String> words) =>
      _preferences.setString(key, jsonEncode(words));
}

class InMemoryWordRecordsStore implements WordRecordsStore {
  List<String> _history = const [];
  List<String> _favorites = const [];
  List<ReviewCard> _reviewCards = const [];
  double _textScale = 1;

  @override
  Future<List<String>> loadHistory() async => List.unmodifiable(_history);

  @override
  Future<void> saveHistory(List<String> words) async {
    _history = List.of(words);
  }

  @override
  Future<List<String>> loadFavorites() async => List.unmodifiable(_favorites);

  @override
  Future<void> saveFavorites(List<String> words) async {
    _favorites = List.of(words);
  }

  @override
  Future<List<ReviewCard>> loadReviewCards() async =>
      List.unmodifiable(_reviewCards);

  @override
  Future<void> saveReviewCards(List<ReviewCard> cards) async {
    _reviewCards = List.of(cards);
  }

  @override
  Future<double> loadTextScale() async => _textScale;

  @override
  Future<void> saveTextScale(double scale) async {
    _textScale = _boundedTextScale(scale);
  }
}

double _boundedTextScale(double scale) => scale.clamp(0.6, 2.0).toDouble();
