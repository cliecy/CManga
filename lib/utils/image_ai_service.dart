import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:cmanga/foundation/appdata.dart';
import 'image_ai_cache.dart';

@immutable
class ImageAiStatus {
  final String message;
  final String? backend;
  final bool isError;
  final bool isProcessing;
  final bool cacheHit;
  final String? errorCode;
  final String? errorDetail;
  final ImageAiCacheRef? cacheRef;

  const ImageAiStatus({
    required this.message,
    this.backend,
    this.isError = false,
    this.isProcessing = false,
    this.cacheHit = false,
    this.errorCode,
    this.errorDetail,
    this.cacheRef,
  });
}

class ImageAiFailure implements Exception {
  const ImageAiFailure(
    this.code,
    this.message, {
    this.detail,
    this.previewBytes,
  });

  final String code;
  final String message;
  final String? detail;
  final Uint8List? previewBytes;

  bool get isResourceLimit =>
      code == 'image_too_large' || code == 'memory_limit';

  @override
  String toString() => message;
}

/// Shared native AI protocol, model identities and serial native operations.
/// Native code retains unrendered inference results; Dart caches rendered PNGs.
class ImageAiService {
  ImageAiService._();
  static final instance = ImageAiService._();
  static const _channel = MethodChannel(
    'com.cmanga.reader/colorize',
  );
  final status = ValueNotifier<ImageAiStatus>(
    const ImageAiStatus(message: 'AI has not been initialized'),
  );
  Map<String, dynamic> _capabilities = const {'supported': false};
  Map<String, dynamic> get capabilities => Map.unmodifiable(_capabilities);
  bool get isSupported => _capabilities['supported'] == true;
  Future<bool>? _initializing;
  String? _cacheDirectory;
  final _cache = ImageAiCache.instance;
  final _identities = <String, ({String signature, String id})>{};
  final _modelInfo = <String, Map<String, dynamic>>{};
  final _hashing = <String, Future<String>>{};
  final _probing = <String, Future<Map<String, dynamic>>>{};
  final _inFlight = <String, Future<Map<String, dynamic>>>{};
  final _queue = Queue<Future<void> Function()>();
  bool _running = false;
  int _generation = 0;

  void reportError(Object error, {String? operation}) {
    final detail = error is PlatformException
        ? (error.message ?? error.code)
        : error.toString();
    final code = error is PlatformException
        ? error.code.toLowerCase()
        : error is ImageAiFailure
        ? error.code
        : null;
    final resourceLimited = code == 'image_too_large' || code == 'memory_limit';
    status.value = ImageAiStatus(
      message: resourceLimited
          ? 'This comic has very large images; super-resolution is not recommended.'
          : '${operation == null ? '' : '$operation: '}$detail',
      isError: true,
      errorCode: code,
      errorDetail: resourceLimited ? detail : null,
    );
  }

  Future<bool> init() => _initializing ??= _initialize().then((supported) {
    if (!supported) _initializing = null;
    return supported;
  });

  Future<void> updateCacheLimits() {
    int? bytes(dynamic value) {
      if (value is! num ||
          !value.isFinite ||
          value < 1 ||
          value > 1048576 ||
          value != value.roundToDouble()) {
        return null;
      }
      return value.toInt() * 1024 * 1024;
    }

    final overrides = <String, int>{};
    final comicSettings = appdata.settings['comicSpecificSettings'];
    if (comicSettings is Map) {
      for (final entry in comicSettings.entries) {
        final settings = entry.value;
        if (entry.key is! String ||
            settings is! Map ||
            settings['enabled'] != true) {
          continue;
        }
        final limit = bytes(settings['imageAiCacheSizeMiB']);
        if (limit != null) overrides[entry.key as String] = limit;
      }
    }
    return _cache.setLimits(
      defaultMaxBytes:
          bytes(appdata.settings['imageAiCacheSizeMiB']) ??
          2 * 1024 * 1024 * 1024,
      comicMaxBytes: overrides,
    );
  }

  String resolveBackend(String backend) {
    if (backend != 'auto' && backend != 'cpu' && backend != 'metal') {
      throw ArgumentError('Unknown AI backend: $backend');
    }
    // Old persisted CPU selections migrate to the user's Apple GPU policy.
    if (Platform.isMacOS || Platform.isIOS) return 'metal';
    if (backend == 'metal') {
      throw UnsupportedError('Metal is available only on Apple devices');
    }
    return backend;
  }

  Future<bool> _initialize() async {
    if (!Platform.isWindows &&
        !Platform.isAndroid &&
        !Platform.isMacOS &&
        !Platform.isIOS) {
      _capabilities = const {
        'supported': false,
        'types': <String>[],
        'backends': <String>[],
        'reason':
            'Native AI is supported only on Windows, Android, macOS and iOS',
      };
      reportError(_capabilities['reason']!);
      return false;
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      _capabilities =
          result ??
          const {'supported': false, 'reason': 'No AI capabilities returned'};
      if (!isSupported) {
        reportError(_capabilities['reason'] ?? 'Native AI is unavailable');
        return false;
      }
      await updateCacheLimits();
      _cacheDirectory = await _cache.directory();
      status.value = const ImageAiStatus(
        message: 'AI backend available; select a compatible model',
      );
      return true;
    } catch (error) {
      reportError(error, operation: 'AI initialization failed');
      return false;
    }
  }

  Future<void> _requireSupport(String type) async {
    if (!await init()) {
      throw UnsupportedError(
        _capabilities['reason'] as String? ?? status.value.message,
      );
    }
    if (!(_capabilities['types'] as List? ?? const []).contains(type)) {
      throw UnsupportedError('AI processing type "$type" is not supported');
    }
  }

  /// Hash the file stream, not the path. Stat changes and all managed installs
  /// invalidate the memoized digest; concurrent readers share the same stream.
  Future<String> modelIdentity(String modelPath) async {
    final stat = await File(modelPath).stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      _identities.remove(modelPath);
      throw StateError('Model is missing or empty: $modelPath');
    }
    final signature =
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
    final known = _identities[modelPath];
    if (known?.signature == signature) return known!.id;
    final key = '$modelPath:$signature';
    final active = _hashing[key];
    if (active != null) return active;
    final future = () async {
      final id = (await sha256.bind(File(modelPath).openRead()).first)
          .toString();
      final after = await File(modelPath).stat();
      if (signature !=
          '${after.size}:${after.modified.microsecondsSinceEpoch}:${after.changed.microsecondsSinceEpoch}') {
        throw StateError('Model changed while computing its identity; retry');
      }
      if (known != null && known.id != id) {
        _modelInfo.removeWhere((key, _) => key.startsWith('$modelPath\u0000'));
        // Native sessions must not keep a model replaced at the same path.
        await resetSession();
      }
      _identities[modelPath] = (signature: signature, id: id);
      return id;
    }();
    _hashing[key] = future;
    try {
      return await future;
    } finally {
      _hashing.remove(key);
    }
  }

  Future<Map<String, dynamic>> getModelInfo(
    String modelPath,
    String type,
  ) async {
    try {
      await _requireSupport(type);
      final id = await modelIdentity(modelPath);
      final key = '$modelPath\u0000$id\u0000$type';
      final cached = _modelInfo[key];
      if (cached != null) return Map.unmodifiable(cached);
      final probing = _probing[key];
      if (probing != null) return await probing;
      final future = _serial(() async {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'getModelInfo',
          {'modelPath': modelPath, 'type': type},
        );
        if (result == null ||
            (type == 'esrgan'
                ? result['channels'] != 1 && result['channels'] != 3
                : result['channels'] !=
                      (type == 'manga_v2'
                          ? 5
                          : type == 'manga_light'
                          ? 1
                          : 3)) ||
            result['scale'] is! int ||
            (result['scale'] as int) < 1 ||
            (type != 'esrgan' && result['scale'] != 1) ||
            result['inputWidth'] is! int ||
            result['inputHeight'] is! int) {
          throw StateError('Native AI returned invalid model metadata');
        }
        return result;
      });
      _probing[key] = future;
      try {
        final info = await future;
        if (_modelInfo.length >= 16) _modelInfo.remove(_modelInfo.keys.first);
        _modelInfo[key] = info;
        status.value = ImageAiStatus(
          message:
              '${type == 'esrgan' ? 'Super-resolution' : 'Colorization'} model ready (${info['scale']}×)',
        );
        return Map.unmodifiable(info);
      } finally {
        _probing.remove(key);
      }
    } catch (error) {
      reportError(error, operation: 'Model validation failed');
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    // The reader admits pixel work one page at a time. Metadata and callers
    // wait their turn instead of turning a full queue into a lost page.
    final completer = Completer<T>();
    _queue.add(() async {
      try {
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _drain();
    return completer.future;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        await _queue.removeFirst()();
      }
    } finally {
      _running = false;
    }
  }

  Future<Map<String, dynamic>> process(
    Map<String, dynamic> arguments, {
    void Function(ImageAiStatus)? onStatus,
    bool forceReprocess = false,
    String? cacheScope,
  }) async {
    var operation = 'AI processing failed';
    try {
      final type = arguments['type'] as String;
      await updateCacheLimits();
      await _requireSupport(type);
      final bytes = arguments['imageBytes'] as Uint8List;
      final modelPath = arguments['modelPath'] as String;
      final id = await modelIdentity(modelPath);
      operation =
          '${type == 'esrgan' ? 'Super-resolution' : 'Colorization'} · '
          '${path.basename(modelPath)} [${id.substring(0, 8)}]';
      await getModelInfo(modelPath, type);
      final modelSignature = _identities[modelPath]?.signature;
      final inputId = sha256.convert(bytes).toString();
      final backend = resolveBackend(arguments['backend'] as String? ?? 'auto');
      final nativeArgs = <String, dynamic>{
        ...arguments,
        'modelId': id,
        'inputId': inputId,
        'backend': backend,
        'cacheDirectory': _cacheDirectory!,
        'forceReprocess': forceReprocess,
      };
      // Exact doubles, not display rounding. Upstream SR changes alter inputId.
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'render-v3',
                type,
                inputId,
                id,
                backend,
                nativeArgs['intensity'],
                nativeArgs['strength'],
                nativeArgs['outputScale'],
              ]),
            ),
          )
          .toString();
      final generation = _generation;
      final cacheRef = ImageAiCacheRef(type, key, scope: cacheScope);
      final requestKey = jsonEncode([
        generation,
        cacheScope,
        key,
        forceReprocess,
      ]);
      final active = _inFlight[requestKey];
      if (active != null) {
        final result = await active;
        onStatus?.call(_resultStatus(result, operation, cacheRef));
        return result;
      }
      final future = _serial(() async {
        final stat = await File(modelPath).stat();
        final signature =
            '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
        if (generation != _generation ||
            signature != modelSignature ||
            _identities[modelPath]?.id != id) {
          throw StateError(
            'AI model changed while this page was queued; reload the page',
          );
        }
        final cached = forceReprocess
            ? null
            : await _cache.read(type, key, scope: cacheScope);
        if (cached != null &&
            cached.metadata['backend'] is String &&
            cached.metadata['scale'] is int &&
            (backend != 'metal' ||
                cached.metadata['backend'] == 'metal' ||
                cached.metadata['backend'] == 'none')) {
          final result = <String, dynamic>{
            ...cached.metadata,
            'imageBytes': cached.bytes,
            'cacheHit': true,
            'renderedCacheHit': true,
          };
          status.value = _resultStatus(result, operation, cacheRef);
          return result;
        }
        status.value = ImageAiStatus(
          message: '$operation: processing',
          isProcessing: true,
        );
        onStatus?.call(status.value);
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'colorize',
          nativeArgs,
        );
        if (result == null ||
            result['imageBytes'] is! Uint8List ||
            (result['imageBytes'] as Uint8List).isEmpty ||
            result['backend'] is! String ||
            result['scale'] is! int ||
            result['cacheHit'] is! bool) {
          throw StateError('Native AI returned an invalid image result');
        }
        if (backend == 'metal' &&
            result['backend'] != 'metal' &&
            result['backend'] != 'none') {
          throw const ImageAiFailure(
            'backend_unavailable',
            'Apple AI requires Metal GPU inference; CPU fallback is disabled.',
          );
        }
        if (generation == _generation) {
          try {
            await _cache.write(
              type,
              key,
              result['imageBytes'] as Uint8List,
              metadata: {...result}..remove('imageBytes'),
              scope: cacheScope,
            );
          } on FileSystemException catch (error) {
            // Preserve real output, but do not claim it will survive reopening.
            result['cacheWarning'] =
                'Processed output could not be cached: $error';
          }
        }
        status.value = _resultStatus(result, operation, cacheRef);
        return result;
      });
      _inFlight[requestKey] = future;
      try {
        final result = await future;
        onStatus?.call(_resultStatus(result, operation, cacheRef));
        return result;
      } finally {
        _inFlight.remove(requestKey);
      }
    } catch (error) {
      reportError(error, operation: operation);
      onStatus?.call(status.value);
      rethrow;
    }
  }

  ImageAiStatus _resultStatus(
    Map<String, dynamic> result,
    String operation,
    ImageAiCacheRef cacheRef,
  ) {
    final backend = result['backend'] as String;
    final hit = result['cacheHit'] == true;
    final fallback = result['fallbackReason'] as String?;
    return ImageAiStatus(
      message:
          '$operation: ${result['renderedCacheHit'] == true
              ? 'Rendered image cache'
              : hit
              ? 'Inference cache; rendered'
              : backend == 'none'
              ? 'Base image rendered; inference skipped'
              : 'AI processed'}'
          '${backend == 'none' ? '' : ' ($backend)'}${fallback == null ? '' : ' — $fallback'}'
          '${result['cacheWarning'] == null ? '' : ' — ${result['cacheWarning']}'}',
      backend: backend,
      cacheHit: hit,
      cacheRef: result['cacheWarning'] == null ? cacheRef : null,
    );
  }

  Future<void> clearRenderedCache(String type) async {
    _generation++;
    await updateCacheLimits();
    await _serial(() => _cache.clear(type));
  }

  Future<int> cacheSize(String type) async {
    await updateCacheLimits();
    return _cache.size(type);
  }

  Future<void> resetSession() async {
    _generation++;
    _modelInfo.clear();
    if (!await init()) return;
    await _serial(() => _channel.invokeMethod<void>('resetSession'));
  }

  Future<int> copyModelFile(String source, String target) async {
    await File(target).parent.create(recursive: true);
    if (Platform.isAndroid) {
      final count = await _channel.invokeMethod<int>('copyUri', {
        'uri': source,
        'destPath': target,
      });
      if (count == null) {
        throw StateError('Native model copy returned no byte count');
      }
      return count;
    }
    final file = source.startsWith('file:')
        ? File.fromUri(Uri.parse(source))
        : File(source);
    final sink = File(target).openWrite();
    try {
      await sink.addStream(file.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
    return File(target).length();
  }

  Future<void> installModelFile(
    String source,
    String target,
    String type, {
    bool preserveBackup = false,
  }) async {
    final staged = '$target.${DateTime.now().microsecondsSinceEpoch}.install';
    try {
      await copyModelFile(source, staged);
      await installStagedModel(
        staged,
        target,
        type,
        preserveBackup: preserveBackup,
      );
    } catch (error) {
      reportError(error, operation: 'Model import failed');
      rethrow;
    } finally {
      if (await File(staged).exists()) await File(staged).delete();
    }
  }

  /// Validate before replacing. A same-directory rename publishes the complete
  /// file; a rollback copy protects the old model even if replacement fails.
  Future<void> installStagedModel(
    String staged,
    String target,
    String type, {
    bool preserveBackup = false,
  }) async {
    if (path.equals(staged, target)) {
      throw ArgumentError('Staging and target paths must differ');
    }
    await getModelInfo(staged, type);
    _generation++;
    await _serial(() async {
      // Keep release, replacement, and identity invalidation in one queue slot.
      await _channel.invokeMethod<void>('resetSession');
      _generation++;
      _modelInfo.clear();
      final rollback = '$target.rollback';
      final existed = await File(target).exists();
      if (existed) await copyModelFile(target, rollback);
      var restored = false;
      try {
        await File(staged).rename(target);
        _identities.remove(staged);
        _identities.remove(target);
        if (existed && preserveBackup && !await File('$target.bak').exists()) {
          await File(rollback).rename('$target.bak');
        }
        restored = true;
      } catch (_) {
        if (existed && await File(rollback).exists()) {
          await File(rollback).rename(target);
        }
        restored = true;
        rethrow;
      } finally {
        // Retain the recovery copy if even rollback failed (e.g. disk failure).
        if (restored && await File(rollback).exists()) {
          await File(rollback).delete();
        }
      }
    });
    status.value = const ImageAiStatus(
      message: 'Compatible AI model installed',
    );
  }
}
