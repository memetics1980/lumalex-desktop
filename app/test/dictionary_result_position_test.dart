import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/models/dictionary_result_position.dart';

void main() {
  test('dictionary result position follows the selected library item', () {
    const paths = ['cdepe', 'ldoce', 'oald', 'oald-zhen', 'oxford-thesaurus'];

    expect(dictionaryResultPositionLabel(paths, 'cdepe'), '1/5');
    expect(dictionaryResultPositionLabel(paths, 'ldoce'), '2/5');
    expect(dictionaryResultPositionLabel(paths, 'oald'), '3/5');
    expect(dictionaryResultPositionLabel(paths, 'oald-zhen'), '4/5');
    expect(dictionaryResultPositionLabel(paths, 'oxford-thesaurus'), '5/5');
  });

  test('dictionary result position handles an unavailable selection', () {
    expect(dictionaryResultPositionLabel(const [], null), '0/0');
    expect(
        dictionaryResultPositionLabel(const ['first', 'second'], null), '–/2');
  });
}
