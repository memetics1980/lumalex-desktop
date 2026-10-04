import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/ios_dictionary_home.dart';

void main() {
  test('creates Dictionaries below the application Documents directory',
      () async {
    final documents =
        await Directory.systemTemp.createTemp('lumalex-documents-');
    addTearDown(() => documents.delete(recursive: true));
    final home = IosDictionaryHome(
      documentsDirectoryProvider: () async => documents,
      isIos: true,
    );

    final directory = await home.ensureExists();

    expect(
      directory?.path,
      '${documents.path}${Platform.pathSeparator}Dictionaries',
    );
    expect(await directory!.exists(), isTrue);
  });

  test('does not create an iOS dictionary folder on other platforms', () async {
    final documents =
        await Directory.systemTemp.createTemp('lumalex-documents-');
    addTearDown(() => documents.delete(recursive: true));
    final home = IosDictionaryHome(
      documentsDirectoryProvider: () async => documents,
      isIos: false,
    );

    expect(await home.ensureExists(), isNull);
    expect(await Directory('${documents.path}/Dictionaries').exists(), isFalse);
  });

  test('removes only a redundant copied folder directly below Dictionaries',
      () async {
    final documents =
        await Directory.systemTemp.createTemp('lumalex-documents-');
    addTearDown(() => documents.delete(recursive: true));
    final home = IosDictionaryHome(
      documentsDirectoryProvider: () async => documents,
      isIos: true,
    );
    final dictionaryHome = await home.ensureExists();
    final copied = Directory('${dictionaryHome!.path}/Imported Dictionary');
    await copied.create();
    await File('${copied.path}/sample.mdx').writeAsString('dictionary');

    expect(await home.removeRedundantCopiedImport(copied.path), isTrue);
    expect(await copied.exists(), isFalse);
    expect(await dictionaryHome.exists(), isTrue);
    expect(
      await home.removeRedundantCopiedImport(dictionaryHome.path),
      isFalse,
    );
  });
}
