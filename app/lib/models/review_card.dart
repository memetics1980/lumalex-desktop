enum ReviewRating { again, hard, good, easy }

/// The small, durable learning record paired with a favorite word.
///
/// Dictionary files stay outside of this record. A short saved gloss is only
/// a convenience for reviewing offline; the full entry remains available from
/// the lookup page.
class ReviewCard {
  const ReviewCard({
    required this.word,
    required this.dueAt,
    required this.intervalDays,
    required this.repetitions,
    required this.lapses,
    this.gloss,
    this.lastReviewedAt,
  });

  factory ReviewCard.newWord(
    String word, {
    required DateTime now,
    String? gloss,
  }) =>
      ReviewCard(
        word: word.trim(),
        dueAt: now,
        intervalDays: 0,
        repetitions: 0,
        lapses: 0,
        gloss: _cleanGloss(gloss),
      );

  factory ReviewCard.fromJson(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Review card must be an object.');
    }
    final rawWord = value['word'];
    final rawDueAt = value['dueAt'];
    if (rawWord is! String || rawWord.trim().isEmpty || rawDueAt is! num) {
      throw const FormatException('Review card is missing required fields.');
    }
    final dueAtMilliseconds = rawDueAt.toInt();
    if (dueAtMilliseconds < 0) {
      throw const FormatException('Review card has an invalid due time.');
    }
    return ReviewCard(
      word: rawWord.trim(),
      dueAt: DateTime.fromMillisecondsSinceEpoch(dueAtMilliseconds),
      intervalDays: _nonNegativeInt(value['intervalDays']),
      repetitions: _nonNegativeInt(value['repetitions']),
      lapses: _nonNegativeInt(value['lapses']),
      gloss: _cleanGloss(
          value['gloss'] is String ? value['gloss'] as String : null),
      lastReviewedAt: value['lastReviewedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (value['lastReviewedAt'] as num).toInt(),
            )
          : null,
    );
  }

  final String word;
  final DateTime dueAt;
  final int intervalDays;
  final int repetitions;
  final int lapses;
  final String? gloss;
  final DateTime? lastReviewedAt;

  Map<String, Object> toJson() => {
        'word': word,
        'dueAt': dueAt.millisecondsSinceEpoch,
        'intervalDays': intervalDays,
        'repetitions': repetitions,
        'lapses': lapses,
        if (gloss != null) 'gloss': gloss!,
        if (lastReviewedAt != null)
          'lastReviewedAt': lastReviewedAt!.millisecondsSinceEpoch,
      };

  ReviewCard copyWith({
    DateTime? dueAt,
    int? intervalDays,
    int? repetitions,
    int? lapses,
    String? gloss,
    bool clearGloss = false,
    DateTime? lastReviewedAt,
  }) =>
      ReviewCard(
        word: word,
        dueAt: dueAt ?? this.dueAt,
        intervalDays: intervalDays ?? this.intervalDays,
        repetitions: repetitions ?? this.repetitions,
        lapses: lapses ?? this.lapses,
        gloss: clearGloss ? null : _cleanGloss(gloss) ?? this.gloss,
        lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      );
}

/// Keeps review records aligned with favorites and seeds newly-saved words as
/// due immediately. Matching is case-insensitive, as MDX headwords are.
List<ReviewCard> synchronizeReviewCards(
  Iterable<String> favorites,
  Iterable<ReviewCard> stored, {
  required DateTime now,
}) {
  final existingByWord = <String, ReviewCard>{
    for (final card in stored) card.word.trim().toLowerCase(): card,
  };
  final seen = <String>{};
  final synchronized = <ReviewCard>[];
  for (final rawWord in favorites) {
    final word = rawWord.trim();
    final key = word.toLowerCase();
    if (word.isEmpty || !seen.add(key)) {
      continue;
    }
    final existing = existingByWord[key];
    synchronized.add(
      existing == null
          ? ReviewCard.newWord(word, now: now)
          : ReviewCard(
              word: word,
              dueAt: existing.dueAt,
              intervalDays: existing.intervalDays,
              repetitions: existing.repetitions,
              lapses: existing.lapses,
              gloss: existing.gloss,
              lastReviewedAt: existing.lastReviewedAt,
            ),
    );
  }
  return synchronized;
}

List<ReviewCard> dueReviewCards(
  Iterable<ReviewCard> cards, {
  required DateTime now,
}) =>
    cards.where((card) => !card.dueAt.isAfter(now)).toList(growable: false)
      ..sort((left, right) {
        final dueOrder = left.dueAt.compareTo(right.dueAt);
        return dueOrder != 0
            ? dueOrder
            : left.word.toLowerCase().compareTo(right.word.toLowerCase());
      });

ReviewCard scheduleReview(
  ReviewCard card,
  ReviewRating rating, {
  required DateTime now,
}) {
  final currentInterval = card.intervalDays;
  final nextInterval = switch (rating) {
    ReviewRating.again => 0,
    ReviewRating.hard =>
      currentInterval == 0 ? 1 : (currentInterval * 1.3).round().clamp(1, 365),
    ReviewRating.good =>
      currentInterval == 0 ? 3 : (currentInterval * 2).clamp(3, 365),
    ReviewRating.easy =>
      currentInterval == 0 ? 7 : (currentInterval * 3).clamp(7, 365),
  }
      .toInt();
  final dueAt = rating == ReviewRating.again
      ? now.add(const Duration(minutes: 10))
      : now.add(Duration(days: nextInterval));
  return card.copyWith(
    dueAt: dueAt,
    intervalDays: nextInterval,
    repetitions:
        rating == ReviewRating.again ? 0 : card.repetitions.saturatingAdd(1),
    lapses: rating == ReviewRating.again
        ? card.lapses.saturatingAdd(1)
        : card.lapses,
    lastReviewedAt: now,
  );
}

/// Extracts a compact offline prompt from a publisher article. It is not a
/// replacement for the full entry: markup is intentionally discarded so the
/// review card remains small and works without a WebView.
String? reviewGlossFromHtml(String html, {int maximumLength = 300}) {
  if (maximumLength <= 0) {
    return null;
  }
  var text = html
      .replaceAll(
        RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
          RegExp(r'</(p|div|li|h[1-6]|tr)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  const entities = <String, String>{
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
  };
  for (final entity in entities.entries) {
    text = text.replaceAll(entity.key, entity.value);
  }
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return null;
  }
  return normalized.length <= maximumLength
      ? normalized
      : '${normalized.substring(0, maximumLength - 1).trimRight()}…';
}

extension on int {
  int saturatingAdd(int value) => this >= 999999 ? 999999 : this + value;
}

int _nonNegativeInt(Object? value) =>
    value is num ? value.toInt().clamp(0, 999999) : 0;

String? _cleanGloss(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
