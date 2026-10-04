import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/dictionary_result_navigation.dart';

void main() {
  const paths = ['cdepe', 'ldoce', 'oald', 'oald-zhen', 'thesaurus'];
  const results = {'cdepe', 'oald', 'thesaurus'};

  test('moves in both directions and skips dictionaries without a result', () {
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'cdepe',
        forward: true,
      ),
      'oald',
    );
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'thesaurus',
        forward: false,
      ),
      'oald',
    );
  });

  test('does not wrap at either end', () {
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'thesaurus',
        forward: true,
      ),
      isNull,
    );
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'cdepe',
        forward: false,
      ),
      isNull,
    );
  });

  test('moves away from a selected dictionary without a result', () {
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'ldoce',
        forward: true,
      ),
      'oald',
    );
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: 'ldoce',
        forward: false,
      ),
      'cdepe',
    );
  });

  test('chooses the nearest boundary result when selection is unavailable', () {
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: null,
        forward: true,
      ),
      'cdepe',
    );
    expect(
      adjacentDictionaryResultPath(
        orderedMdxPaths: paths,
        resultMdxPaths: results,
        selectedMdxPath: null,
        forward: false,
      ),
      'thesaurus',
    );
  });
}
