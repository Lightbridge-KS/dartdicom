// The Implementation Version Name follows the package version (VM only: it
// reads pubspec.yaml).
@TestOn('vm')
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

void main() {
  test('the version name carries the pubspec version, without prerelease', () {
    final version = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())!
        .group(1);
    expect(dartdicomImplementationVersionName, 'DARTDICOM $version');
  });
}
