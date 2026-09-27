import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:cmanga/foundation/app.dart';
import 'package:cmanga/foundation/appdata.dart';

/// Persistent on-disk cache for image responses.
///
/// The in-memory [NetworkCacheManager] layer only lives for the app session
/// and its default TTL is 5 seconds, so re-reading an online chapter always
/// meant re-downloading every page. This layer keeps raw image bytes on disk
/// for a much longer window (7 days), making revisits to recently read
/// chapters cost zero bandwidth.
class DiskImageCache {
  DiskImageCache._({Directory? dir}) : _dirOverride = dir;

  static final DiskImageCache instance = DiskImageCache._();

  /// Per-entry cap: do not store unusually large files (4 MiB).
  static const int maxEntryBytes = 4 * 1024 * 1024;

  /// Entries older than this are treated as stale and dropped on read.
  static const Duration ttl = Duration(days: 7);

  final Directory? _dirOverride;

  late final Directory _dir =
      _dirOverride ?? Directory(p.join(App.cachePath, 'image_cache'));

  int _totalBytes = -1; // -1 = not measured yet

  void _ensureInit() {
    try {
      if (!_dir.existsSync()) {
        _dir.createSync(recursive: true);
      }
    } catch (_) {}
  }

  String _keyFor(Uri uri) => sha256.convert(utf8.encode(uri.toString())).toString();

  File _file(String key) => File(p.join(_dir.path, '$key.bin'));

  /// Returns the cached bytes when a fresh entry exists; null otherwise.
  Uint8List? get(Uri uri) {
    _ensureInit();
    var file = _file(_keyFor(uri));
    try {
      if (!file.existsSync()) return null;
      var st = file.statSync();
      if (DateTime.now().difference(st.modified) > ttl) {
        file.deleteSync();
        _totalBytes -= st.size;
        return null;
      }
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  /// Stores [bytes] for [uri]. Silently ignores oversized or empty payloads.
  void put(Uri uri, List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxEntryBytes) return;
    _ensureInit();
    try {
      var file = _file(_keyFor(uri));
      file.writeAsBytesSync(bytes);
      if (_totalBytes < 0) {
        _measureTotal();
      } else {
        _totalBytes += bytes.length;
      }
      evictIfNeeded();
    } catch (_) {}
  }

  int get totalBytes => _totalBytes < 0 ? 0 : _totalBytes;

  void _measureTotal() {
    var total = 0;
    try {
      for (var f in _dir.listSync()) {
        if (f is File) total += f.lengthSync();
      }
    } catch (_) {}
    _totalBytes = total;
  }

  /// Keeps total usage under the configured limit by deleting oldest entries.
  void evictIfNeeded() {
    var limitMB = appdata.settings['imageDiskCacheSize'];
    var limit = (limitMB is int && limitMB > 0 ? limitMB : 512) * 1024 * 1024;
    if (_totalBytes <= limit) return;
    try {
      var files = _dir
          .listSync()
          .whereType<File>()
          .map((f) => (file: f, mtime: f.statSync().modified))
          .toList()
        ..sort((a, b) => a.mtime.compareTo(b.mtime));
      for (var entry in files) {
        if (_totalBytes <= limit) break;
        var size = entry.file.lengthSync();
        entry.file.deleteSync();
        _totalBytes -= size;
      }
    } catch (_) {}
  }

  /// Removes all cached images (used by the "Clear Cache" action).
  void clear() {
    try {
      if (_dir.existsSync()) {
        _dir.deleteSync(recursive: true);
      }
    } catch (_) {}
    _totalBytes = 0;
  }
}
