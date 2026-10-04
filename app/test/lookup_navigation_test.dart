import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/lookup_navigation.dart';

void main() {
  const first = LookupLocation(
    query: 'first',
    mdxPath: '/dictionary.mdx',
    scrollOffset: 420,
  );
  const second = LookupLocation(
    query: 'second',
    mdxPath: '/dictionary.mdx',
    scrollOffset: 180,
  );

  test('back and forward preserve lookup locations', () {
    final history = LookupNavigationHistory();
    history.recordDeparture(first);

    expect(history.goBackFrom(second), same(first));
    expect(history.canGoForward, isTrue);
    expect(history.goForwardFrom(first), same(second));
  });

  test('a new departure clears the forward stack', () {
    final history = LookupNavigationHistory();
    history.recordDeparture(first);
    history.goBackFrom(second);
    history.recordDeparture(first);

    expect(history.canGoForward, isFalse);
  });
}
