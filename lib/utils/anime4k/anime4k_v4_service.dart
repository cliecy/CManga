import 'dart:typed_data';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/image_ai_service.dart';

import 'anime4k_v4_model_manager.dart';

/// AI super-resolution using the same real model on Windows and Android.
/// Failure preserves the reader image; it never silently selects v1.
class Anime4KV4Service {
  Anime4KV4Service._internal();
  static final _instance = Anime4KV4Service._internal();
  factory Anime4KV4Service() => _instance;
  static Anime4KV4Service get instance => _instance;

  final _ai = ImageAiService.instance;
  String? _modelPath;
  Map<String, dynamic>? _modelInfo;
  Map<String, dynamic>? get modelInfo => _modelInfo;
  int? get modelScale => _modelInfo?['scale'] as int?;
  bool get isAvailable =>
      _ai.isSupported && _modelPath != null && _modelInfo != null;

  Future<void> init() async {
    if (!await _ai.init()) return;
    await Anime4KV4ModelManager.setSelectedModelId(
      appdata.settings['anime4KV4Model'] as String? ?? 'anime4k_acnet',
    );
    await Anime4KV4ModelManager.extractBundledModelIfNeeded();
    await checkModelAvailable();
  }

  Future<void> setModel(String id) async {
    if (!Anime4KV4ModelManager.isValidModelId(id)) return;
    _modelInfo = null;
    _modelPath = null;
    await Anime4KV4ModelManager.setSelectedModelId(id);
    appdata.settings['anime4KV4Model'] = id;
    appdata.saveData();
    await resetNativeSession();
    await Anime4KV4ModelManager.extractBundledModelIfNeeded();
    await checkModelAvailable();
  }

  Future<bool> checkModelAvailable() async {
    _modelInfo = null;
    _modelPath = null;
    try {
      if (!await _ai.init()) return false;
      final modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
      if (modelPath == null) {
        _ai.reportError('Super-resolution model is not installed');
        return false;
      }
      final info = await _ai.getModelInfo(modelPath, 'esrgan');
      _modelPath = modelPath;
      _modelInfo = info;
      return true;
    } catch (error) {
      _ai.reportError(error, operation: 'Super-resolution model unavailable');
      return false;
    }
  }

  Future<void> resetNativeSession() async {
    _modelInfo = null;
    _modelPath = null;
    await _ai.resetSession();
  }

  Future<Uint8List?> processImage({
    required Uint8List imageBytes,
    required String cacheKey,
    double intensity = 1.0,
    double outputScale = 0.0,
    double strength = 1.0,
    String backend = 'auto',
  }) async {
    try {
      if (!await _ai.init()) return null;
      final modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
      if (modelPath == null) {
        throw StateError('Super-resolution model is not installed');
      }
      final info = await _ai.getModelInfo(modelPath, 'esrgan');
      _modelPath = modelPath;
      _modelInfo = info;
      final result = await _ai.process({
        'imageBytes': imageBytes,
        'modelPath': modelPath,
        'type': 'esrgan',
        'backend': backend,
        'intensity': intensity,
        'strength': strength,
        'outputScale': outputScale,
      });
      return result['imageBytes'] as Uint8List;
    } catch (error) {
      _ai.reportError(
        error,
        operation: 'Super-resolution failed; page not enhanced',
      );
      return null;
    }
  }

  Future<void> clearCache() => _ai.clearRenderedCache('esrgan');
  Future<int> getCacheSize() => _ai.cacheSize('esrgan');
}
