/// The pinned DICOM release: where its XML comes from, and its checksums.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

/// The DICOM Standard release the dictionary is generated from.
const release = '2026d';

/// SHA-256 of each pinned source file. A download that doesn't match is
/// refused, so a regeneration is reproducible even after NEMA's `current`
/// moves on to the next release.
const checksums = {
  'part06.xml':
      'fa9f0f8d67eba692dcf95cfeae0a8f4e071beeb7844215a860bc4b9d5dfaad25',
  'part07.xml':
      '979da8b222a47d80260a5463ad1c2767bcc7966b6c5c2893daefedbd6c99b3df',
};

/// Where a release's files are cached: `$DARTDICOM_CACHE`, else
/// `$XDG_CACHE_HOME/dartdicom`, else `~/.cache/dartdicom`.
Directory cacheDir() {
  final env = Platform.environment;
  final root = env['DARTDICOM_CACHE'] ??
      (env['XDG_CACHE_HOME'] != null
          ? '${env['XDG_CACHE_HOME']}/dartdicom'
          : '${env['HOME']}/.cache/dartdicom');
  return Directory('$root/dicom-standard/$release');
}

/// The release's own URL first; `current` is only valid while [release] is
/// the newest, and the checksum guards it.
List<Uri> sourceUrls(String file) {
  final part = file.replaceAll('.xml', '');
  const base = 'https://dicom.nema.org/medical/dicom';
  return [
    Uri.parse('$base/$release/source/docbook/$part/$file'),
    Uri.parse('$base/current/source/docbook/$part/$file'),
  ];
}

/// The verified local copy of [file], downloaded on first use.
Future<File> fetch(String file) async {
  final target = File('${cacheDir().path}/$file');
  if (target.existsSync() && _sha256(target) == checksums[file]) return target;

  target.parent.createSync(recursive: true);
  final client = HttpClient();
  try {
    for (final url in sourceUrls(file)) {
      stderr.writeln('downloading $url');
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        continue;
      }
      final partial = File('${target.path}.part');
      await response.pipe(partial.openWrite());
      final digest = _sha256(partial);
      if (digest == checksums[file]) return partial.renameSync(target.path);
      partial.deleteSync();
      stderr.writeln('  checksum mismatch ($digest); not release $release');
    }
  } finally {
    client.close();
  }
  throw StateError('no source for $file matches the $release checksum');
}

String _sha256(File f) => sha256.convert(f.readAsBytesSync()).toString();
