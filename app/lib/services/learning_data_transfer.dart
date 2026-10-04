import 'dart:convert';

import '../models/review_card.dart';

class LearningDataBackup {
  LearningDataBackup({
    required this.exportedAt,
    required this.history,
    required this.favorites,
    required this.reviewCards,
    required this.textScale,
  });

  static const schemaVersion = 1;

  factory LearningDataBackup.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<Object?, Object?> ||
        decoded['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported LumaLex learning-data backup.');
    }
    final rawExportedAt = decoded['exportedAt'];
    final exportedAt =
        rawExportedAt is String ? DateTime.tryParse(rawExportedAt) : null;
    if (exportedAt == null) {
      throw const FormatException('The backup has no valid export timestamp.');
    }
    final reviewCards = <ReviewCard>[];
    for (final value in _list(decoded['reviewCards'])) {
      try {
        reviewCards.add(ReviewCard.fromJson(value));
      } on FormatException {
        // Keep valid records when one old or edited row is malformed.
      }
    }
    return LearningDataBackup(
      exportedAt: exportedAt,
      history: _cleanWords(decoded['history'], limit: 200),
      favorites: _cleanWords(decoded['favorites']),
      reviewCards: List.unmodifiable(reviewCards),
      textScale:
          ((decoded['textScale'] is num ? decoded['textScale'] as num : 1)
                  .toDouble())
              .clamp(0.6, 2.0)
              .toDouble(),
    );
  }

  final DateTime exportedAt;
  final List<String> history;
  final List<String> favorites;
  final List<ReviewCard> reviewCards;
  final double textScale;

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': schemaVersion,
        'exportedAt': exportedAt.toUtc().toIso8601String(),
        'history': history,
        'favorites': favorites,
        'reviewCards':
            reviewCards.map((card) => card.toJson()).toList(growable: false),
        'textScale': textScale,
      });
}

List<Object?> _list(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

List<String> _cleanWords(Object? value, {int? limit}) {
  final seen = <String>{};
  final words = <String>[];
  for (final word in _list(value).whereType<String>()) {
    final normalized = word.trim();
    if (normalized.isEmpty || !seen.add(normalized.toLowerCase())) continue;
    words.add(normalized);
    if (limit != null && words.length >= limit) break;
  }
  return List.unmodifiable(words);
}
