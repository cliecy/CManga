import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zip_flutter/zip_flutter.dart';
import 'package:cmanga/utils/safe_extract.dart';

/// Fixtures are embedded so the test is self-contained. The traversal and
/// symlink archives cannot be produced by zip_flutter's own API (it would
/// normalize what we need to smuggle in), hence raw base64.
const _goodZip =
    'UEsDBBQAAAAAAAAAIQCFEUoNCwAAAAsAAAAHAAAAYS9iLnR4dGhlbGxvIHdvcmxk'
    'UEsBAhQDFAAAAAAAAAAhAIURSg0LAAAACwAAAAcAAAAAAAAAAAAAAKSBAAAAAGEvYi50eHRQSwUGAAAAAAEAAQA1AAAAMAAAAAAA';

const _traversalZip =
    'UEsDBBQAAAAAAAAAIQB+UwTZBQAAAAUAAAALAAAALi4vZXZpbC50eHRwd25lZFBL'
    'AwQUAAAAAAC8sTpdklSpvgQAAAAEAAAABgAAAG9rLnR4dGZpbmVQSwECFAMUAAAAAAAAACEAflME2QUAAAAFAAAACwAAAAAAAAAAAAAApIEAAAAALi4vZXZpbC50eHRQSwECFAMUAAAAAAC8sTpdklSpvgQAAAAEAAAABgAAAAAAAAAAAAAAgAEuAAAAb2sudHh0UEsFBgAAAAACAAIAbQAAAFYAAAAAAA==';

const _symlinkZip =
    'UEsDBBQAAAAAAAAAIQAKuR8pCwAAAAsAAAAEAAAAbGluay9ldGMvcGFzc3dkUEsBAhQDFAAAAAAAAAAhAAq5HykLAAAACwAAAAQAAAAAAAAAAAAAAP+hAAAAAGxpbmtQSwUGAAAAAAEAAQAyAAAALQAAAAAA';

bool _nativeZipAvailable() {
  try {
    DynamicLibrary.open('libzip_flutter.so');
    return true;
  } catch (_) {
    // The desktop app build produces this library; plain `flutter test`
    // checkouts may not have it. Name validation below still runs.
    return false;
  }
}

void main() {
  group('safeJoin', () {
    test('accepts normal relative paths inside outDir', () {
      var target = SafeExtract.safeJoin('/out', 'a/b.txt');
      expect(target, p.join(p.absolute('/out'), 'a', 'b.txt'));
    });

    for (var bad in [
      '../evil.txt',
      '../../etc/passwd',
      '/etc/passwd',
      r'C:\windows\system32\evil.dll',
      'a/../../../b',
      'name\x00withnul',
      '',
    ]) {
      test('rejects unsafe name: ${bad.replaceAll('\x00', '<NUL>')}', () {
        expect(SafeExtract.safeJoin('/out', bad), isNull);
      });
    }
  });

  var nativeSkip = !_nativeZipAvailable()
      ? 'libzip_flutter.so not loadable in this environment'
      : false;

  group('extractZip end-to-end', () {
    late String outDir;
    late String fixtures;

    setUp(() {
      outDir = Directory.systemTemp.createTempSync('safe_extract_out').path;
      fixtures =
          Directory.systemTemp.createTempSync('safe_extract_fix').path;
      File(p.join(fixtures, 'good.zip'))
          .writeAsBytesSync(base64Decode(_goodZip));
      File(p.join(fixtures, 'traversal.zip'))
          .writeAsBytesSync(base64Decode(_traversalZip));
      File(p.join(fixtures, 'symlink.zip'))
          .writeAsBytesSync(base64Decode(_symlinkZip));
      // Two 600-byte entries: total exceeds the 1024 cap used below.
      var x = File(p.join(fixtures, 'x.bin'))
        ..writeAsBytesSync(List.filled(600, 65));
      var y = File(p.join(fixtures, 'y.bin'))
        ..writeAsBytesSync(List.filled(600, 66));
      var bomb = ZipFile.open(p.join(fixtures, 'bomb.zip'));
      bomb.addFile('x.bin', x.path);
      bomb.addFile('y.bin', y.path);
      bomb.close();
    });

    tearDown(() {
      for (var dir in [outDir, fixtures]) {
        if (Directory(dir).existsSync()) {
          Directory(dir).deleteSync(recursive: true);
        }
      }
    });

    test('extracts a normal archive', () {
      SafeExtract.extractZip('$fixtures/good.zip', outDir);
      var file = File(p.join(outDir, 'a', 'b.txt'));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), 'hello world');
    }, skip: nativeSkip);

    test('rejects path traversal and writes nothing outside outDir', () {
      var parent = p.dirname(outDir);
      expect(() => SafeExtract.extractZip('$fixtures/traversal.zip', outDir),
          throwsA(isA<UnsafeArchiveException>()));
      // The archive lists ../evil.txt before ok.txt; extraction must abort.
      expect(File(p.join(parent, 'evil.txt')).existsSync(), isFalse);
    }, skip: nativeSkip);

    test('enforces the total uncompressed size cap', () {
      expect(
          () => SafeExtract.extractZip('$fixtures/bomb.zip', outDir,
              maxTotalBytes: 1024),
          throwsA(isA<UnsafeArchiveException>()));
      // Partially written entries are cleaned up.
      expect(File(p.join(outDir, 'x.bin')).existsSync(), isFalse);
    }, skip: nativeSkip);

    test('symlink entry becomes a plain file, never a real symlink', () {
      SafeExtract.extractZip('$fixtures/symlink.zip', outDir);
      var link = File(p.join(outDir, 'link'));
      expect(link.existsSync(), isTrue);
      expect(FileSystemEntity.typeSync(link.path), FileSystemEntityType.file);
      // Content is the target string, not a dereferenced /etc/passwd.
      expect(link.readAsStringSync(), '/etc/passwd');
    }, skip: nativeSkip);

    test('pre-existing symlink at entry path is replaced', () {
      var linkPath = p.join(outDir, 'link');
      Link(linkPath).createSync('/etc/passwd');
      SafeExtract.extractZip('$fixtures/symlink.zip', outDir);
      expect(FileSystemEntity.typeSync(linkPath), FileSystemEntityType.file);
    }, skip: nativeSkip);
  });
}
