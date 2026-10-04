import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/reader_diagnostics.dart';

void main() {
  test('reader diagnostics retain only the newest events', () {
    expect(
      trimReaderDiagnosticLinesForTesting(
        ['one', 'two', 'three', 'four'],
        maximumLines: 2,
      ),
      ['three', 'four'],
    );
  });

  test('reader diagnostics accept an empty retention limit', () {
    expect(
      trimReaderDiagnosticLinesForTesting(['one'], maximumLines: 0),
      isEmpty,
    );
  });
}
