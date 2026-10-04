import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/review_card.dart';

void main() {
  final now = DateTime(2026, 9, 13, 10);

  test('synchronization seeds favorites immediately and drops removed words',
      () {
    final stored = ReviewCard.newWord('Old', now: now)
        .copyWith(dueAt: now.add(const Duration(days: 3)));

    final cards = synchronizeReviewCards(
      const ['New', 'OLD', 'new'],
      [stored],
      now: now,
    );

    expect(cards.map((card) => card.word), ['New', 'OLD']);
    expect(cards.first.dueAt, now);
    expect(cards.last.dueAt, now.add(const Duration(days: 3)));
  });

  test('ratings create predictable first-review intervals', () {
    final card = ReviewCard.newWord('increase', now: now);

    expect(
      scheduleReview(card, ReviewRating.again, now: now).dueAt,
      now.add(const Duration(minutes: 10)),
    );
    expect(
      scheduleReview(card, ReviewRating.hard, now: now).intervalDays,
      1,
    );
    expect(
      scheduleReview(card, ReviewRating.good, now: now).intervalDays,
      3,
    );
    expect(
      scheduleReview(card, ReviewRating.easy, now: now).intervalDays,
      7,
    );
  });

  test('due cards are ordered by due time then word', () {
    final cards = [
      ReviewCard.newWord('zebra', now: now),
      ReviewCard.newWord('apple', now: now),
      ReviewCard.newWord('later', now: now)
          .copyWith(dueAt: now.add(const Duration(days: 1))),
    ];

    expect(
      dueReviewCards(cards, now: now).map((card) => card.word),
      ['apple', 'zebra'],
    );
  });

  test('review gloss removes markup and script content', () {
    expect(
      reviewGlossFromHtml(
        '<style>.hidden { display:none }</style><p>increase &amp; grow</p>'
        '<script>ignore()</script><p>变大</p>',
      ),
      'increase & grow 变大',
    );
  });
}
