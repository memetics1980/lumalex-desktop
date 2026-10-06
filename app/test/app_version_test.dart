import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/app_version.dart';

void main() {
  test('displayed app version matches the build configuration', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(version, isNotNull);
    expect(lumalexVersionName, version!.group(1));
    expect(lumalexBuildNumber, int.parse(version.group(2)!));
  });
}
