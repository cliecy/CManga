import 'dart:typed_data';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/image_ai_service.dart';

import 'anime4k_v4_model_manager.dart';

/// AI super-resolution using the same real models on all supported native platforms.
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
    final id = Anime4KV4ModelManager.migrateModelId(
      appdata.settings['anime4KV4Model'] as String? ?? 'anime4k_acnet',
    );
    if (appdata.settings['anime4KV4Model'] != id) {
      appdata.settings['anime4KV4Model'] = id;
      await appdata.saveData();
    }
    await Anime4KV4ModelManager.setSelectedModelId(id);
    await Anime4KV4ModelManager.extractBundledModelIfNeeded();
    await checkModelAvailable();
  }

  Future<void> setModel(String id) async {
    id = Anime4KV4ModelManager.migrateModelId(id);
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
    bool forceReprocess = false,
    void Function(ImageAiStatus)? onStatus,
    String? cacheScope,
  }) async {
    var reportedFailure = false;
    try {
      if (!await _ai.init()) {
        throw UnsupportedError(
          _ai.capabilities['reason']?.toString() ?? 'AI backend unavailable',
        );
      }
      final model = Anime4KV4ModelManager.selectedDef;
      final modelPath = await Anime4KV4ModelManager.ensureModelAvailable(
        model: model,
      );
      if (modelPath == null) {
        throw StateError('Super-resolution model is not installed');
      }
      final info = await _ai.getModelInfo(modelPath, 'esrgan');
      _modelPath = modelPath;
      _modelInfo = info;
      final result = await _ai.process(
        {
          'imageBytes': imageBytes,
          'modelPath': modelPath,
          'type': 'esrgan',
          'backend': backend,
          'intensity': intensity,
          'strength': strength,
          'outputScale': outputScale,
        },
        forceReprocess: forceReprocess,
        cacheScope: cacheScope,
        onStatus: (value) {
          reportedFailure = value.isError;
          onStatus?.call(value);
        },
      );
      return result['imageBytes'] as Uint8List;
    } catch (error) {
      if (reportedFailure) return null;
      _ai.reportError(
        error,
        operation: 'Super-resolution failed; page not enhanced',
      );
      onStatus?.call(_ai.status.value);
      return null;
    }
  }

  Future<void> clearCache() => _ai.clearRenderedCache('esrgan');
  Future<int> getCacheSize() => _ai.cacheSize('esrgan');
}
