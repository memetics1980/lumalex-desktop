import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/services/dictionary_file_access.dart';

void main() {
  test('identical MDX bytes have one fingerprint across paths', () async {
    final root = await Directory.systemTemp.createTemp('lumalex-fingerprint-');
    addTearDown(() => root.delete(recursive: true));
    final first = File('${root.path}/first.mdx');
    final second = File('${root.path}/renamed.mdx');
    await first.writeAsBytes(List<int>.generate(4096, (index) => index % 251));
    await second.writeAsBytes(await first.readAsBytes());
    final access = DictionaryFileAccess();

    final firstFingerprint = await access.fingerprintMdx(first.path);
    final secondFingerprint = await access.fingerprintMdx(second.path);

    expect(firstFingerprint, startsWith('sha256:'));
    expect(secondFingerprint, firstFingerprint);
  });

  test('different MDX bytes have different fingerprints', () async {
    final root = await Directory.systemTemp.createTemp('lumalex-fingerprint-');
    addTearDown(() => root.delete(recursive: true));
    final first = File('${root.path}/first.mdx')..writeAsStringSync('first');
    final second = File('${root.path}/second.mdx')..writeAsStringSync('second');
    final access = DictionaryFileAccess();

    expect(
      await access.fingerprintMdx(first.path),
      isNot(await access.fingerprintMdx(second.path)),
    );
  });

  test('replacing a local MDX invalidates its cached fingerprint', () async {
    final root = await Directory.systemTemp.createTemp('lumalex-fingerprint-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/dictionary.mdx');
    await source.writeAsString('first');
    final access = DictionaryFileAccess();

    final firstVersion = await access.sourceVersionForMdx(source.path);
    final firstFingerprint = await access.fingerprintMdx(source.path);
    await source.writeAsString('a different replacement');
    final secondVersion = await access.sourceVersionForMdx(source.path);
    final secondFingerprint = await access.fingerprintMdx(source.path);

    expect(secondVersion, isNot(firstVersion));
    expect(secondFingerprint, isNot(firstFingerprint));
  });
}
