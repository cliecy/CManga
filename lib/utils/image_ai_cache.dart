import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Encoded AI results survive reader and process lifetimes. Never stores source
/// pages or decoded bitmaps; all engines share one bounded, least-recently-used
/// disk budget. A checksum binds metadata to its atomically published PNG.
class ImageAiCache {
  ImageAiCache._();
  static final instance = ImageAiCache._();
  static const maxBytes = 2 * 1024 * 1024 * 1024;
  String? _directory;
  Future<void>? _initializing;
  Future<void> _pending = Future.value();

  Future<String> directory() async {
    await init();
    return _directory!;
  }

  Future<void> init() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    final support = await getApplicationSupportDirectory();
    final temporary = await getTemporaryDirectory();
    _directory = path.join(support.path, 'image_ai_cache_v2');
    final destination = Directory(_directory!);
    await destination.create(recursive: true);
    // Keep already completed work when moving the old temporary native cache.
    final old = Directory(path.join(temporary.path, 'image_ai_cache_v2'));
    if (old.path != destination.path && await old.exists()) {
      await for (final file in old.list()) {
        if (file is! File ||
            !RegExp(
              r'^[a-z0-9_]+_[a-f0-9]{64}\.(png|json)$',
            ).hasMatch(path.basename(file.path))) {
          continue;
        }
        final target = path.join(destination.path, path.basename(file.path));
        if (await File(target).exists()) continue;
        try {
          await file.rename(target);
        } on FileSystemException {
          await file.copy(target);
          await file.delete();
        }
      }
    }
    // The legacy algorithm used the same digests but no metadata sidecars.
    final legacy = Directory(path.join(temporary.path, 'anime4k_cache'));
    if (await legacy.exists()) {
      await for (final file in legacy.list()) {
        if (file is! File) continue;
        final match = RegExp(
          r'^(base|render)_([a-f0-9]{64})\.png$',
        ).firstMatch(path.basename(file.path));
        if (match == null) continue;
        final stem = _stem('v1_${match[1]}', match[2]!);
        if (await File('$stem.json').exists()) continue;
        final bytes = await file.readAsBytes();
        if (!_isPng(bytes)) continue;
        await _write(stem, bytes, const {});
        await file.delete();
      }
    }
    await _trim();
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _stem(String group, String key) {
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(group) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Invalid AI cache identity');
    }
    return path.join(_directory!, '${group}_$key');
  }

  static bool _isPng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    const end = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
    if (bytes.length < 45) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    for (var i = 0; i < end.length; i++) {
      if (bytes[bytes.length - end.length + i] != end[i]) return false;
    }
    return true;
  }

  Future<({Uint8List bytes, Map<String, dynamic> metadata})?> read(
    String group,
    String key,
  ) async {
    await init();
    return _serial(() async {
      final stem = _stem(group, key);
      final image = File('$stem.png');
      final sidecar = File('$stem.json');
      try {
        if (!await image.exists() || !await sidecar.exists()) return null;
        final metadata = Map<String, dynamic>.from(
          jsonDecode(await sidecar.readAsString()) as Map,
        );
        final bytes = await image.readAsBytes();
        if (!_isPng(bytes)) return null;
        final digest = sha256.convert(bytes).toString();
        if (metadata.containsKey('encodedSha256') &&
            (metadata['encodedSha256'] != digest ||
                metadata['encodedLength'] != bytes.length)) {
          return null;
        }
        // Older native entries are upgraded once, without repeating inference.
        if (!metadata.containsKey('encodedSha256')) {
          await _atomicWrite(
            sidecar.path,
            utf8.encode(
              jsonEncode({
                ...metadata,
                'encodedSha256': digest,
                'encodedLength': bytes.length,
              }),
            ),
          );
        }
        final now = DateTime.now();
        await sidecar.setLastModified(now);
        await image.setLastModified(now);
        metadata.remove('encodedSha256');
        metadata.remove('encodedLength');
        return (bytes: bytes, metadata: metadata);
      } on FileSystemException {
        return null;
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      }
    });
  }

  Future<void> write(
    String group,
    String key,
    Uint8List bytes, {
    Map<String, dynamic> metadata = const {},
  }) async {
    await init();
    await _serial(() async {
      await _write(_stem(group, key), bytes, metadata);
      await _trim();
    });
  }

  Future<void> _write(
    String stem,
    Uint8List bytes,
    Map<String, dynamic> metadata,
  ) async {
    if (!_isPng(bytes)) {
      throw const FormatException('AI cache accepts complete PNG images only');
    }
    final encoded = utf8.encode(
      jsonEncode({
        ...metadata,
        'encodedSha256': sha256.convert(bytes).toString(),
        'encodedLength': bytes.length,
      }),
    );
    await _atomicWrite('$stem.png', bytes);
    await _atomicWrite('$stem.json', encoded);
  }

  Future<void> _atomicWrite(String target, List<int> bytes) async {
    final temporary = File(
      '$target.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _trim() async {
    final entries = <({File image, File metadata, int size, DateTime used})>[];
    var total = 0;
    await for (final file in Directory(_directory!).list()) {
      if (file is! File || !file.path.endsWith('.png')) continue;
      final metadata = File(
        '${file.path.substring(0, file.path.length - 4)}.json',
      );
      final stat = await file.stat();
      final sidecar = await metadata.stat();
      final size =
          stat.size +
          (sidecar.type == FileSystemEntityType.file ? sidecar.size : 0);
      entries.add((
        image: file,
        metadata: metadata,
        size: size,
        used: stat.modified,
      ));
      total += size;
    }
    entries.sort((a, b) => a.used.compareTo(b.used));
    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (await entry.image.exists()) await entry.image.delete();
      if (await entry.metadata.exists()) await entry.metadata.delete();
      total -= entry.size;
    }
  }

  Future<void> clear(String group) async {
    await init();
    await _serial(() async {
      await for (final file in Directory(_directory!).list()) {
        if (file is File && path.basename(file.path).startsWith('${group}_')) {
          await file.delete();
        }
      }
    });
  }

  Future<int> size(String group) async {
    await init();
    return _serial(() async {
      var bytes = 0;
      await for (final file in Directory(_directory!).list()) {
        if (file is File && path.basename(file.path).startsWith('${group}_')) {
          bytes += await file.length();
        }
      }
      return bytes;
    });
  }
}
