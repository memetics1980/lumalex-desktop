import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/review_card.dart';
import 'package:local_dictionary/services/learning_data_transfer.dart';

void main() {
  test('learning data round-trips without dictionary content', () {
    final exportedAt = DateTime.utc(2026, 9, 18, 8, 30);
    final backup = LearningDataBackup(
      exportedAt: exportedAt,
      history: const ['word', 'example'],
      favorites: const ['word'],
      reviewCards: [
        ReviewCard.newWord(
          'word',
          now: exportedAt,
          gloss: 'a compact definition',
        ),
      ],
      textScale: 1.2,
    );

    final encoded = backup.encode();
    final restored = LearningDataBackup.decode(encoded);

    expect(restored.exportedAt, exportedAt);
    expect(restored.history, const ['word', 'example']);
    expect(restored.favorites, const ['word']);
    expect(restored.reviewCards.single.word, 'word');
    expect(restored.reviewCards.single.gloss, 'a compact definition');
    expect(restored.textScale, 1.2);
    expect(encoded, isNot(contains('.mdx')));
    expect(encoded, isNot(contains('content://')));
  });

  test('learning data sanitizes duplicates and invalid values', () {
    final restored = LearningDataBackup.decode('''
{
  "schemaVersion": 1,
  "exportedAt": "2026-09-18T08:30:00.000Z",
  "history": [" Word ", "word", ""],
  "favorites": ["Alpha", "ALPHA", 7],
  "reviewCards": [{"word": "Alpha", "dueAt": 0}, {"bad": true}],
  "textScale": 99
}
''');

    expect(restored.history, const ['Word']);
    expect(restored.favorites, const ['Alpha']);
    expect(restored.reviewCards, hasLength(1));
    expect(restored.textScale, 2);
  });

  test('learning data rejects an unknown schema', () {
    expect(
      () => LearningDataBackup.decode(
        '{"schemaVersion":2,"exportedAt":"2026-09-18T00:00:00Z"}',
      ),
      throwsFormatException,
    );
  });
}
