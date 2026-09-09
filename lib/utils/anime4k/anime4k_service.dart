import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/log.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../image_ai_service.dart';
import 'anime4k_upscaler.dart';

/// Anime4K 超分服务
///
/// 提供图像超分辨率处理功能，支持缓存机制以避免重复处理。
/// 采用单例模式，通过 [Anime4KService.instance] 访问。
class Anime4KService {
  Anime4KService._internal();

  static final Anime4KService _instance = Anime4KService._internal();

  factory Anime4KService() => _instance;

  static Anime4KService get instance => _instance;

  /// 缓存目录路径
  String? _cacheDir;

  final _inFlight =
      <String, Future<({Uint8List? bytes, ImageAiStatus status})?>>{};
  int _queuedBytes = 0;
  int _generation = 0;

  /// 最大并发处理数
  static const int _maxConcurrentTasks = 1;

  /// 当前正在运行的任务数
  int _runningTasks = 0;

  /// 任务队列
  final List<Function> _taskQueue = [];

  /// 初始化缓存目录
  Future<void> init() async {
    try {
      final dir = await getTemporaryDirectory();
      _cacheDir = path.join(dir.path, 'anime4k_cache');
      final cacheDirectory = Directory(_cacheDir!);
      if (!await cacheDirectory.exists()) {
        await cacheDirectory.create(recursive: true);
      }
    } catch (e) {
      Log.error('Anime4K', 'Anime4K cache init error: $e');
    }
  }

  /// 获取缓存文件路径
  ///
  /// 使用 key 的 SHA-256 作为文件名，避免 [String.hashCode] 哈希碰撞导致
  /// 不同图片命中彼此的缓存（显示错图）。
  String? _getCachePath(String key) {
    if (_cacheDir == null) return null;
    final hash = sha256.convert(utf8.encode(key)).toString();
    return path.join(
      _cacheDir!,
      '${key.startsWith('v1-base-') ? 'base' : 'render'}_$hash.png',
    );
  }

  /// 检查是否有缓存，有则返回缓存数据
  Future<Uint8List?> _getFromCache(String key) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return null;

    final file = File(cachePath);
    if (await file.exists()) {
      try {
        return await file.readAsBytes();
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  /// 保存处理结果到缓存
  Future<void> _saveToCache(String key, Uint8List data) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return;

    try {
      final file = File(cachePath);
      await file.writeAsBytes(data);
      final entries = <({File file, FileStat stat})>[];
      var total = 0;
      await for (final entry in Directory(_cacheDir!).list()) {
        if (entry is File) {
          final stat = await entry.stat();
          entries.add((file: entry, stat: stat));
          total += stat.size;
        }
      }
      entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
      for (final entry in entries) {
        if (total <= 256 * 1024 * 1024) break;
        await entry.file.delete();
        total -= entry.stat.size;
      }
    } catch (e) {
      Log.error('Anime4K', 'Anime4K cache save error: $e');
    }
  }

  /// 处理图片字节数据，返回超分后的 PNG 字节数据
  ///
  /// [imageBytes] 原始图片字节数据
  /// [cacheKey] 缓存键，用于避免重复处理（通常使用图片 URL 或文件路径）
  /// [scaleFactor] 放大倍数（默认 2.0）
  /// [pushStrength] 线条细化强度（默认 0.31）
  /// [pushGradStrength] 梯度精炼强度（默认 1.0）
  Future<Uint8List?> processImage({
    required Uint8List imageBytes,
    required String cacheKey,
    double scaleFactor = 2.0,
    double pushStrength = 0.31,
    double pushGradStrength = 1.0,
    double strength = 1.0,
    void Function(ImageAiStatus)? onStatus,
  }) async {
    if (!scaleFactor.isFinite ||
        scaleFactor < 1 ||
        scaleFactor > 4 ||
        !strength.isFinite ||
        strength < 0 ||
        strength > 1 ||
        !pushStrength.isFinite ||
        pushStrength < 0 ||
        pushStrength > 2 ||
        !pushGradStrength.isFinite ||
        pushGradStrength < 0 ||
        pushGradStrength > 2) {
      ImageAiService.instance.reportError(
        'Invalid v1 scale or enhancement strength',
      );
      onStatus?.call(ImageAiService.instance.status.value);
      return null;
    }
    final inputId = sha256.convert(imageBytes).toString();
    final baseKey =
        'v1-base-v3:$inputId:$scaleFactor:$pushStrength:$pushGradStrength';
    final fullKey = 'v1-render-v3:$baseKey:$strength';
    final existing = _inFlight[fullKey];
    if (existing != null) {
      final result = (await existing)!;
      onStatus?.call(result.status);
      return result.bytes;
    }
    if (_taskQueue.length >= 16 ||
        _queuedBytes + imageBytes.length > 128 * 1024 * 1024) {
      ImageAiService.instance.reportError(
        'Super-resolution queue is full; reload this page',
      );
      onStatus?.call(ImageAiService.instance.status.value);
      return null;
    }
    _queuedBytes += imageBytes.length;
    final generation = _generation;
    final future = _enqueueTask<({Uint8List? bytes, ImageAiStatus status})>(
      () async {
        try {
          if (_cacheDir == null) await init();
          final cached = await _getFromCache(fullKey);
          if (cached != null) {
            const resultStatus = ImageAiStatus(
              message: 'v1 rendered image cache (CPU)',
              backend: 'cpu',
              cacheHit: true,
            );
            ImageAiService.instance.status.value = resultStatus;
            return (bytes: cached, status: resultStatus);
          }
          ImageAiService.instance.status.value = const ImageAiStatus(
            message: 'v1 super-resolution processing (CPU)',
            backend: 'cpu',
            isProcessing: true,
          );
          Uint8List? enhanced;
          var baseCacheHit = false;
          if (strength > 0) {
            enhanced = await _getFromCache(baseKey);
            baseCacheHit = enhanced != null;
            enhanced ??= await Anime4KUpscaler.processInIsolate(
              Anime4KParams(
                imageBytes: imageBytes,
                pushStrength: pushStrength,
                pushGradStrength: pushGradStrength,
                scaleFactor: scaleFactor,
              ),
            );
            if (enhanced == null) {
              throw StateError('v1 could not decode or enhance this image');
            }
            if (!baseCacheHit && generation == _generation) {
              await _saveToCache(baseKey, enhanced);
            }
          }
          final result = await Anime4KUpscaler.renderInIsolate(
            Anime4KRenderParams(
              imageBytes: imageBytes,
              enhancedBytes: enhanced,
              scaleFactor: scaleFactor,
              strength: strength,
            ),
          );
          if (generation == _generation) await _saveToCache(fullKey, result);
          final resultStatus = ImageAiStatus(
            message: strength == 0
                ? 'Base image resized; v1 enhancement skipped'
                : baseCacheHit
                ? 'v1 enhancement cache; strength rendered (CPU)'
                : 'v1 super-resolution complete (CPU)',
            backend: 'cpu',
            cacheHit: baseCacheHit,
          );
          ImageAiService.instance.status.value = resultStatus;
          return (bytes: result, status: resultStatus);
        } catch (error) {
          ImageAiService.instance.reportError(
            error,
            operation: 'v1 super-resolution failed',
          );
          return (bytes: null, status: ImageAiService.instance.status.value);
        } finally {
          _queuedBytes -= imageBytes.length;
        }
      },
    );
    _inFlight[fullKey] = future;
    try {
      final result = (await future)!;
      onStatus?.call(result.status);
      return result.bytes;
    } finally {
      _inFlight.remove(fullKey);
    }
  }

  /// 将任务加入队列并按序执行
  Future<T?> _enqueueTask<T>(Future<T?> Function() task) async {
    final completer = Completer<T?>();

    _taskQueue.add(() async {
      _runningTasks++;
      try {
        final result = await task();
        completer.complete(result);
      } catch (e) {
        completer.completeError(e);
      } finally {
        _runningTasks--;
        _nextTask();
      }
    });

    _nextTask();
    return completer.future;
  }

  /// 执行下一个任务
  void _nextTask() {
    if (_runningTasks < _maxConcurrentTasks && _taskQueue.isNotEmpty) {
      final task = _taskQueue.removeAt(0);
      task();
    }
  }

  /// 处理本地图片文件
  ///
  /// [filePath] 本地图片文件路径
  Future<Uint8List?> processFile({
    required String filePath,
    double scaleFactor = 2.0,
    double pushStrength = 0.31,
    double pushGradStrength = 1.0,
    double strength = 1.0,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final imageBytes = await file.readAsBytes();
      return processImage(
        imageBytes: imageBytes,
        cacheKey: filePath,
        scaleFactor: scaleFactor,
        pushStrength: pushStrength,
        pushGradStrength: pushGradStrength,
        strength: strength,
      );
    } catch (e) {
      Log.error('Anime4K', 'Anime4K file processing error: $e');
      return null;
    }
  }

  /// Clear rendered images without discarding reusable algorithm results.
  Future<void> clearCache() async {
    _generation++;
    if (_cacheDir == null) return;
    try {
      final dir = Directory(_cacheDir!);
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          if (entry is File && !path.basename(entry.path).startsWith('base_')) {
            await entry.delete();
          }
        }
      }
      Log.info('Anime4K', 'Anime4K: cache cleared');
    } catch (e) {
      Log.error('Anime4K', 'Anime4K cache clear error: $e');
    }
  }

  /// 获取缓存占用的磁盘大小（字节）
  Future<int> getCacheSize() async {
    if (_cacheDir == null) return 0;
    try {
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return 0;

      int totalSize = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }
}
