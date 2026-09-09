import 'dart:io';
import 'dart:typed_data';

import 'package:venera/utils/image_ai_service.dart';

import 'colorization_processor.dart';

/// DeOldify colorization. Native capabilities and model validation, rather than
/// a file's name or size, determine whether this service is ready.
class ColorizationService {
  ColorizationService._internal();
  static final _instance = ColorizationService._internal();
  factory ColorizationService() => _instance;
  static ColorizationService get instance => _instance;

  final _ai = ImageAiService.instance;
  String? _modelPath;
  Map<String, dynamic>? _modelInfo;
  Map<String, dynamic>? get modelInfo => _modelInfo;
  bool get isModelAvailable =>
      _ai.isSupported && _modelPath != null && _modelInfo != null;

  Future<void> init() async {
    if (await _ai.init()) await checkModelAvailable();
  }

  Future<bool> checkModelAvailable() async {
    _modelPath = null;
    _modelInfo = null;
    try {
      if (!await _ai.init()) return false;
      final model = await ColorizationModelManager.getSelectedDefinition();
      final modelPath = await ColorizationModelManager.ensureModelAvailable(
        model: model,
      );
      if (modelPath == null) {
        _ai.reportError('Colorization model is not installed');
        return false;
      }
      final info = await _ai.getModelInfo(modelPath, model.type);
      _modelPath = modelPath;
      _modelInfo = info;
      return true;
    } catch (error) {
      _ai.reportError(error, operation: 'Colorization model unavailable');
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
      final model = await ColorizationModelManager.getSelectedDefinition();
      final modelPath = await ColorizationModelManager.ensureModelAvailable(
        model: model,
      );
      if (modelPath == null) {
        throw StateError('Colorization model is not installed');
      }
      final info = await _ai.getModelInfo(modelPath, model.type);
      _modelPath = modelPath;
      _modelInfo = info;
      final result = await _ai.process(
        {
          'imageBytes': imageBytes,
          'modelPath': modelPath,
          'type': model.type,
          'backend': backend,
          'intensity': intensity,
          'strength': 1.0,
          'outputScale': 0.0,
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
        operation: 'Colorization failed; page not colorized',
      );
      onStatus?.call(_ai.status.value);
      return null;
    }
  }

  Future<Uint8List?> processFile({
    required String filePath,
    double intensity = 1.0,
    String backend = 'auto',
  }) async {
    try {
      return await processImage(
        imageBytes: await File(filePath).readAsBytes(),
        cacheKey: filePath,
        intensity: intensity,
        backend: backend,
      );
    } catch (error) {
      _ai.reportError(error, operation: 'Colorization file processing failed');
      return null;
    }
  }

  Future<void> clearCache() async {
    for (final type
        in ColorizationModelManager.modelVariants.map((m) => m.type).toSet()) {
      await _ai.clearRenderedCache(type);
    }
  }

  Future<int> getCacheSize() async {
    var total = 0;
    for (final type
        in ColorizationModelManager.modelVariants.map((m) => m.type).toSet()) {
      total += await _ai.cacheSize(type);
    }
    return total;
  }
}
