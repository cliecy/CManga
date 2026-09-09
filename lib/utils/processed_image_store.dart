import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

class ProcessedImageStore {
  static const directoryName = '.venera-processed';
  static final _random = Random.secure();

  /// Derived images must never become source pages or imported chapters.
  static bool containsPath(String sourcePath) {
    return path
        .split(path.normalize(sourcePath))
        .any((part) => part.toLowerCase() == directoryName);
  }

  /// Persists a completed PNG without changing the source or earlier results.
  /// The caller retains ownership of [bytes] and must not mutate it until done.
  static Future<File> save({
    required String sourcePath,
    required String stage,
    required Uint8List bytes,
  }) async {
    if (stage != 'super_resolution' &&
        stage != 'colorization' &&
        stage != 'super_resolution_colorization') {
      throw ArgumentError.value(stage, 'stage', 'Unknown processing stage');
    }
    if (containsPath(sourcePath)) {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'Already processed');
    }
    final digest = sha256.convert(bytes).toString();
    final directory = Directory(
      path.join(
        path.dirname(sourcePath),
        directoryName,
        stage,
        path.basename(sourcePath),
      ),
    );
    await directory.create(recursive: true);
    final outputPath = path.join(directory.path, '$digest.png');
    if (await File(outputPath).exists()) return File(outputPath);

    // A sibling temporary file also works with Android's SAF IO overrides,
    // which do not implement Directory.createTemp or cross-directory moves.
    String temporaryPath;
    do {
      final nonce = List.generate(
        4,
        (_) => _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
        growable: false,
      ).join();
      temporaryPath = path.join(directory.path, '.$digest.$nonce.tmp');
    } while (await File(temporaryPath).exists());
    try {
      await File(temporaryPath).writeAsBytes(bytes, flush: true);
      if (!await File(outputPath).exists()) {
        try {
          await File(temporaryPath).rename(outputPath);
        } on FileSystemException {
          // Another writer can publish the identical digest between the
          // existence check and rename. Other rename failures still propagate.
          if (!await File(outputPath).exists()) rethrow;
        }
      }
      // SAF can return from rename without throwing when it did not publish.
      if (!await File(outputPath).exists()) {
        throw FileSystemException('Processed image was not saved', outputPath);
      }
      return File(outputPath);
    } finally {
      // Recreate the handle: SAF rename can mutate the original File object.
      final temporary = File(temporaryPath);
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
