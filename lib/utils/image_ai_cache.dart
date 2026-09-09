import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// A lightweight handle to a completed result, without retaining pixel bytes.
class ImageAiCacheRef {
  const ImageAiCacheRef(this.group, this.key, {this.scope});

  final String group;
  final String key;
  final String? scope;

  Future<Uint8List?> read() async =>
      (await ImageAiCache.instance.read(group, key, scope: scope))?.bytes;
}

/// Encoded AI results survive reader and process lifetimes. Unconfigured comics
/// share one LRU budget; configured comics have independent, cross-engine pools.
/// A checksum binds metadata to its atomically published PNG.
class ImageAiCache {
  ImageAiCache._();
  static final instance = ImageAiCache._();
  int _defaultMaxBytes = 2 * 1024 * 1024 * 1024;
  Map<String, int> _comicMaxBytes = const {};
  static final _scopePattern = RegExp(r'^[a-f0-9]{64}$');
  static final _entryPattern = RegExp(
    r'^([a-z0-9_]+)_([a-f0-9]{64})\.(png|json)$',
  );
  String? _directory;
  Future<void>? _initializing;
  Future<void> _pending = Future.value();

  Future<String> directory() async {
    await init();
    return _directory!;
  }

  Future<void> init() => _serial(_ensureInitialized);

  Future<void> _ensureInitialized() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> setLimits({
    required int defaultMaxBytes,
    required Map<String, int> comicMaxBytes,
  }) {
    if (defaultMaxBytes < 0 ||
        comicMaxBytes.values.any((value) => value <= 0)) {
      throw ArgumentError(
        'AI cache limits must be nonnegative, with positive comic quotas',
      );
    }
    final limits = {
      for (final entry in comicMaxBytes.entries)
        _scopeId(entry.key): entry.value,
    };
    return _serial(() async {
      if (_defaultMaxBytes == defaultMaxBytes &&
          _comicMaxBytes.length == limits.length &&
          limits.entries.every(
            (entry) => _comicMaxBytes[entry.key] == entry.value,
          )) {
        return;
      }
      _defaultMaxBytes = defaultMaxBytes;
      _comicMaxBytes = limits;
      // Initial cleanup must use the caller's policy, not the default budget.
      final initialized = _initializing != null;
      await _ensureInitialized();
      if (initialized) await _trim();
    });
  }

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
            !_entryPattern.hasMatch(path.basename(file.path))) {
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

  static String _scopeId(String scope) =>
      sha256.convert(utf8.encode(scope)).toString();

  String _stem(String group, String key, {String? scope}) {
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(group) ||
        !_scopePattern.hasMatch(key)) {
      throw ArgumentError('Invalid AI cache identity');
    }
    final directory = scope == null
        ? _directory!
        : path.join(_directory!, 'scopes', _scopeId(scope));
    return path.join(directory, '${group}_$key');
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
    String key, {
    String? scope,
  }) => _serial(() async {
    await _ensureInitialized();
    final stem = _stem(group, key, scope: scope);
    final result = await _read(stem, allowLegacy: scope == null);
    if (result != null || scope == null) return result;

    // Adopt completed flat entries only after validating the old pair. Publish
    // the scoped pair before deleting the old one, so interruptions lose no work.
    final legacyStem = _stem(group, key);
    final legacy = await _read(legacyStem, allowLegacy: true);
    if (legacy == null) return null;
    try {
      await _write(stem, legacy.bytes, legacy.metadata);
      await File('$legacyStem.png').delete();
      await File('$legacyStem.json').delete();
      await _trim();
    } on FileSystemException catch (error) {
      return (
        bytes: legacy.bytes,
        metadata: {
          ...legacy.metadata,
          'cacheWarning': 'Cached output could not be adopted: $error',
        },
      );
    }
    return legacy;
  });

  Future<({Uint8List bytes, Map<String, dynamic> metadata})?> _read(
    String stem, {
    required bool allowLegacy,
  }) async {
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
      if (metadata.containsKey('encodedSha256')) {
        if (metadata['encodedSha256'] != digest ||
            metadata['encodedLength'] != bytes.length) {
          return null;
        }
      } else {
        if (!allowLegacy) return null;
        // Older native entries are upgraded once, without repeating inference.
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
  }

  Future<void> write(
    String group,
    String key,
    Uint8List bytes, {
    Map<String, dynamic> metadata = const {},
    String? scope,
  }) => _serial(() async {
    await _ensureInitialized();
    await _write(_stem(group, key, scope: scope), bytes, metadata);
    await _trim();
  });

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
    await Directory(path.dirname(stem)).create(recursive: true);
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

  // Only our flat root and hashed scope directories are cache containers.
  // Never recurse through arbitrary paths or follow directory symlinks.
  Stream<File> _files() async* {
    final directories = <Directory>[Directory(_directory!)];
    final scopes = Directory(path.join(_directory!, 'scopes'));
    if (await scopes.exists()) {
      await for (final entry in scopes.list(followLinks: false)) {
        if (entry is Directory &&
            _scopePattern.hasMatch(path.basename(entry.path))) {
          directories.add(entry);
        }
      }
    }
    for (final directory in directories) {
      await for (final file in directory.list(followLinks: false)) {
        if (file is File && _entryPattern.hasMatch(path.basename(file.path))) {
          yield file;
        }
      }
    }
  }

  Future<void> _trim() async {
    final entries =
        <({File image, File metadata, int size, DateTime used, String pool})>[];
    final totals = <String, int>{};
    await for (final file in _files()) {
      if (!file.path.endsWith('.png')) continue;
      final metadata = File(
        '${file.path.substring(0, file.path.length - 4)}.json',
      );
      final stat = await file.stat();
      final sidecar = await metadata.stat();
      final size =
          stat.size +
          (sidecar.type == FileSystemEntityType.file ? sidecar.size : 0);
      final scope = path.basename(path.dirname(file.path));
      final pool = _comicMaxBytes.containsKey(scope) ? scope : '';
      entries.add((
        image: file,
        metadata: metadata,
        size: size,
        used: stat.modified,
        pool: pool,
      ));
      totals[pool] = (totals[pool] ?? 0) + size;
    }
    entries.sort((a, b) {
      final order = a.used.compareTo(b.used);
      return order != 0 ? order : a.image.path.compareTo(b.image.path);
    });
    for (final entry in entries) {
      final limit = _comicMaxBytes[entry.pool] ?? _defaultMaxBytes;
      if (totals[entry.pool]! <= limit) continue;
      if (await entry.image.exists()) await entry.image.delete();
      if (await entry.metadata.exists()) await entry.metadata.delete();
      totals[entry.pool] = totals[entry.pool]! - entry.size;
    }
  }

  Future<void> clear(String group) => _serial(() async {
    await _ensureInitialized();
    await for (final file in _files()) {
      if (_entryPattern.firstMatch(path.basename(file.path))![1] == group) {
        await file.delete();
      }
    }
  });

  Future<int> size(String group) => _serial(() async {
    await _ensureInitialized();
    var bytes = 0;
    await for (final file in _files()) {
      if (_entryPattern.firstMatch(path.basename(file.path))![1] == group) {
        bytes += await file.length();
      }
    }
    return bytes;
  });
}
