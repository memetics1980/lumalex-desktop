import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/dictionary_text_to_speech.dart';

void main() {
  test('system speech is enabled on supported app platforms', () {
    expect(supportsDictionaryTextToSpeechOn('android'), isTrue);
    expect(supportsDictionaryTextToSpeechOn('ios'), isTrue);
    expect(supportsDictionaryTextToSpeechOn('windows'), isTrue);
    expect(supportsDictionaryTextToSpeechOn('macos'), isFalse);
    expect(supportsDictionaryTextToSpeechOn('linux'), isFalse);
  });
}
