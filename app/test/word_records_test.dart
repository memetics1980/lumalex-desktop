import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/review_card.dart';
import 'package:local_dictionary/services/word_records.dart';

void main() {
  test('history is case-insensitively deduplicated with newest first', () {
    expect(
      addRecentWord(['word', 'test'], ' Word '),
      ['Word', 'test'],
    );
  });

  test('history keeps at most 200 words', () {
    final existing = List.generate(200, (index) => 'word-$index');
    final updated = addRecentWord(existing, 'new-word');

    expect(updated, hasLength(200));
    expect(updated.first, 'new-word');
    expect(updated, isNot(contains('word-199')));
  });

  test('saved words toggle without case-sensitive duplicates', () {
    expect(toggleSavedWord(['Test'], 'test'), isEmpty);
    expect(toggleSavedWord(['word'], 'Test'), ['Test', 'word']);
  });

  test('saved words can be removed individually or in a batch', () {
    expect(
      removeSavedWords(['One', 'Two', 'Three'], ['two']),
      ['One', 'Three'],
    );
    expect(
      removeSavedWords(['One', 'Two', 'Three'], ['ONE', 'three']),
      ['Two'],
    );
  });

  test('in-memory store keeps one global text scale', () async {
    final store = InMemoryWordRecordsStore();
    await store.saveTextScale(1.2);

    expect(await store.loadTextScale(), 1.2);
  });

  test('in-memory store keeps review progress separately from favorites',
      () async {
    final store = InMemoryWordRecordsStore();
    final card = ReviewCard.newWord('review', now: DateTime(2026));

    await store.saveReviewCards([card]);

    expect((await store.loadReviewCards()).single.word, 'review');
  });
}
