import 'dart:io';
import 'dart:isolate';

import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:path/path.dart' as p;
import 'package:zip_flutter/zip_flutter.dart';

/// Safe archive extraction with path-traversal and zip-bomb protection.
///
/// The `zip_flutter` C extractor does not sanitize entry names: `..`
/// components survive `zip_name_normalize`, and Unix symlink entries are
/// created as real symlinks which later entries can be written through.
/// `flutter_7zip` concatenates entry names without any normalization.
class UnsafeArchiveException implements Exception {
  final String message;

  const UnsafeArchiveException(this.message);

  @override
  String toString() => 'UnsafeArchiveException: $message';
}

class SafeExtract {
  SafeExtract._();

  /// Default cap on total uncompressed bytes (4 GiB).
  static const int defaultMaxTotalBytes = 4 * 1024 * 1024 * 1024;

  /// Default cap on a single uncompressed entry (1 GiB).
  static const int defaultMaxEntryBytes = 1024 * 1024 * 1024;

  /// Default cap on the number of entries (10 000).
  static const int defaultMaxEntries = 10000;

  /// Resolves an archive entry [name] against [outDir].
  ///
  /// Returns the target path, or null when the name is unsafe (absolute
  /// path, drive letter, `..` component, or escapes [outDir]).
  static String? safeJoin(String outDir, String name) {
    if (name.isEmpty) return null;
    if (name.contains('\x00')) return null;
    var normalized = name.replaceAll('\\', '/');
    if (normalized.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
    var parts = normalized.split('/');
    if (parts.any((part) => part == '..')) return null;
    var base = p.absolute(outDir);
    var target = parts.fold(base, (path, part) => p.join(path, part));
    // Belt and braces: the resolved path must stay inside the target dir.
    if (!p.isWithin(base, target)) return null;
    return target;
  }

  /// Extracts a zip archive to [outDir], validating every entry.
  ///
  /// Synchronous and blocking; run it in an isolate for large archives
  /// (see [extractZipIsolate]).
  static void extractZip(
    String archivePath,
    String outDir, {
    int maxTotalBytes = defaultMaxTotalBytes,
  }) {
    var zip = ZipFile.openRead(archivePath);
    try {
      var entries = zip.getAllEntries();
      if (entries.length > defaultMaxEntries) {
        throw UnsafeArchiveException('Too many entries: ${entries.length}');
      }
      var total = 0;
      for (var entry in entries) {
        if (entry.isDir) continue;
        if (entry.size < 0 || entry.size > defaultMaxEntryBytes) {
          throw UnsafeArchiveException('Entry too large: ${entry.name}');
        }
        total += entry.size;
      }
      if (total > maxTotalBytes) {
        throw UnsafeArchiveException('Uncompressed size exceeds limit');
      }
      var written = 0;
      for (var entry in entries) {
        var target = safeJoin(outDir, entry.name);
        if (target == null) {
          throw UnsafeArchiveException('Unsafe entry name: ${entry.name}');
        }
        if (entry.isDir) {
          _removeSymlinkIfPresent(target);
          Directory(target).createSync(recursive: true);
        } else {
          _removeSymlinkIfPresent(target);
          Directory(p.dirname(target)).createSync(recursive: true);
          var data = entry.read();
          written += data.length;
          if (written > maxTotalBytes) {
            File(target).deleteSync();
            throw UnsafeArchiveException('Uncompressed size exceeds limit');
          }
          File(target).writeAsBytesSync(data);
        }
      }
    } finally {
      zip.close();
    }
  }

  /// Extracts a 7z archive to [outDir], validating every entry.
  ///
  /// Synchronous and blocking; run it in an isolate for large archives
  /// (see [extract7zIsolate]).
  static void extract7z(
    String archivePath,
    String outDir, {
    int maxTotalBytes = defaultMaxTotalBytes,
  }) {
    var archive = SZArchive.open(archivePath);
    try {
      var count = archive.numFiles;
      if (count > defaultMaxEntries) {
        throw UnsafeArchiveException('Too many entries: $count');
      }
      var total = 0;
      for (var i = 0; i < count; i++) {
        var file = archive.getFile(i);
        if (file.isDirectory) continue;
        if (file.size < 0 || file.size > defaultMaxEntryBytes) {
          throw UnsafeArchiveException('Entry too large: ${file.name}');
        }
        total += file.size;
      }
      if (total > maxTotalBytes) {
        throw UnsafeArchiveException('Uncompressed size exceeds limit');
      }
      var written = 0;
      for (var i = 0; i < count; i++) {
        var file = archive.getFile(i);
        var target = safeJoin(outDir, file.name);
        if (target == null) {
          throw UnsafeArchiveException('Unsafe entry name: ${file.name}');
        }
        if (file.isDirectory) {
          _removeSymlinkIfPresent(target);
          Directory(target).createSync(recursive: true);
        } else {
          _removeSymlinkIfPresent(target);
          Directory(p.dirname(target)).createSync(recursive: true);
          var data = archive.extractFile(i);
          written += data.length;
          if (written > maxTotalBytes) {
            File(target).deleteSync();
            throw UnsafeArchiveException('Uncompressed size exceeds limit');
          }
          File(target).writeAsBytesSync(data);
        }
      }
    } finally {
      archive.dispose();
    }
  }

  /// [extractZip] run in an isolate so the UI thread is not blocked.
  static Future<void> extractZipIsolate(
    String archivePath,
    String outDir, {
    int maxTotalBytes = defaultMaxTotalBytes,
  }) {
    return Isolate.run(
        () => extractZip(archivePath, outDir, maxTotalBytes: maxTotalBytes));
  }

  /// [extract7z] run in an isolate so the UI thread is not blocked.
  static Future<void> extract7zIsolate(
    String archivePath,
    String outDir, {
    int maxTotalBytes = defaultMaxTotalBytes,
  }) {
    return Isolate.run(
        () => extract7z(archivePath, outDir, maxTotalBytes: maxTotalBytes));
  }

  /// Deletes [path] when it is a symlink, so a subsequent write or directory
  /// creation cannot follow it to an attacker-chosen target.
  static void _removeSymlinkIfPresent(String path) {
    try {
      // followLinks: false — the default would report the *target's* type
      // and leave a pre-existing symlink in place for the write to follow.
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        Link(path).deleteSync();
      }
    } on FileSystemException {
      // Does not exist: nothing to do.
    }
  }
}
