import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/retained_reader_slots.dart';

void main() {
  test('retained paths keep stable slots while an LRU miss reuses a vacancy',
      () {
    final initial = assignRetainedReaderSlots(
      currentSlots: const [null, null],
      retainedLruPaths: const ['a.mdx', 'b.mdx'],
      slotCount: 2,
    );
    final switched = assignRetainedReaderSlots(
      currentSlots: initial,
      retainedLruPaths: const ['b.mdx', 'c.mdx'],
      slotCount: 2,
    );

    expect(initial, const ['a.mdx', 'b.mdx']);
    expect(switched, const ['c.mdx', 'b.mdx']);
  });

  test('memory-pressure trimming releases all but the selected slot', () {
    expect(
      assignRetainedReaderSlots(
        currentSlots: const ['c.mdx', 'b.mdx'],
        retainedLruPaths: const ['b.mdx'],
        slotCount: 2,
      ),
      const [null, 'b.mdx'],
    );
  });

  test('slot assignment bounds and deduplicates retained paths', () {
    expect(
      assignRetainedReaderSlots(
        currentSlots: const [null, null],
        retainedLruPaths: const ['a.mdx', 'b.mdx', 'a.mdx', 'c.mdx'],
        slotCount: 2,
      ),
      const ['a.mdx', 'c.mdx'],
    );
  });
}
