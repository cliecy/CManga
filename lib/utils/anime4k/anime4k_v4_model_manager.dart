import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cmanga/foundation/log.dart';
import 'package:cmanga/utils/image_ai_service.dart';
import 'package:cmanga/utils/model_download.dart';

/// 单个 v4 超分模型的定义。
///
/// [scale] 仅作 UI 提示；真正的放大倍数与输入通道数（3=RGB / 1=Y）由原生 [ColorizeEngine.getModelInfo] 从模型
/// 实际输入/输出维度探测，因此换权重（4x/2x）无需改原生代码。
class V4ModelDef {
  final String id;
  final String fileName;
  final String displayName;
  final int scale;
  final int sizeHintMB;
  final String? bundledAssetPath;
  final List<String> defaultUrls;
  final String? sha256Digest;
  final String sourceUrl;
  final String licenseNote;
  final String protocolNote;

  const V4ModelDef({
    required this.id,
    required this.fileName,
    required this.displayName,
    required this.scale,
    required this.sizeHintMB,
    this.bundledAssetPath,
    required this.defaultUrls,
    this.sha256Digest,
    required this.sourceUrl,
    required this.licenseNote,
    required this.protocolNote,
  });
}

/// v4 super-resolution lifecycle: ACNet and independently installed Real-ESRGAN
/// models. Captured definitions keep installs isolated from selection changes.
///
/// 模型获取策略（三选一，优先级从高到低）：
///  1. 自选外部模型（用户从本地导入，最高优先，绝不被覆盖）；
///  2. Bundled ACNet, extracted to application support on supported native platforms;
///  3. 运行时下载（下载管理器保留：用户删除模型后可重新下载，或切换镜像/自选模型）。
///
/// Model files are streamed and validated before replacement on every platform.
class Anime4KV4ModelManager {
  /// Lightweight animation defaults and optional general-purpose RRDB models.
  static final List<V4ModelDef> models = [
    V4ModelDef(
      id: 'anime4k_acnet',
      fileName: 'anime4k_acnet.onnx',
      displayName: 'Anime4K v4 ACNet (2×)',
      scale: 2,
      sizeHintMB: 2,
      // The compact official ACNet model is bundled for offline first use.
      bundledAssetPath: 'assets/models/anime4k_acnet.onnx',
      defaultUrls: [
        'https://ghproxy.net/https://github.com/Kiastr/Venera-SSR/releases/download/model/anime4k_acnet.onnx',
        'https://github.com/Kiastr/Venera-SSR/releases/download/model/anime4k_acnet.onnx',
      ],
      sourceUrl: 'https://github.com/TianZerL/Anime4KCPP',
      licenseNote:
          'Official Anime4KCPP ACNet distribution; retain the upstream license and notices.',
      protocolNote:
          'esrgan: 1-channel luminance input/output, 2×; original chroma retained.',
    ),
    V4ModelDef(
      id: 'anime4k_x4',
      fileName: 'realesr_animevideov3.onnx',
      displayName: '动画 4× (Real-ESRGAN)',
      scale: 4,
      sizeHintMB: 4,
      bundledAssetPath: null, // 不再打包：保留为可选下载模型，不破坏原有功能
      defaultUrls: [
        'https://ghproxy.net/https://github.com/Kiastr/Venera-SSR/releases/download/model/realesr_animevideov3.onnx',
        'https://github.com/Kiastr/Venera-SSR/releases/download/model/realesr_animevideov3.onnx',
      ],
      sourceUrl: 'https://github.com/xinntao/Real-ESRGAN',
      licenseNote:
          'Real-ESRGAN: BSD-3-Clause; existing third-party animevideov3 ONNX distribution.',
      protocolNote:
          'esrgan: RGB 0..1 → RGB 0..1, 4×; lightweight animation model.',
    ),
    V4ModelDef(
      id: 'realesrgan_x2plus',
      fileName: 'realesrgan_x2plus.onnx',
      displayName: 'RealESRGAN-x2plus (~67 MB, slower, general-purpose)',
      scale: 2,
      sizeHintMB: 67,
      defaultUrls: [
        'https://huggingface.co/SceneWorks/real-esrgan-onnx/resolve/09f741bac80a246b407da3ee902bf5f3291b602f/real_esrgan_x2.onnx',
      ],
      sha256Digest:
          '7115ba92e8a1bfa63d68558ef006ef3d91273a068d321b1439f8bb1c9179002c',
      sourceUrl: 'https://huggingface.co/SceneWorks/real-esrgan-onnx',
      licenseNote:
          'BSD-3-Clause. Weights: Xintao Wang / Real-ESRGAN; ONNX export: SceneWorks. Preserve copyright, license and disclaimer. Not manga-specialized; GAN may redraw details.',
      protocolNote:
          'esrgan: float32 [1,3,H,W] RGB 0..1 → [1,3,2H,2W]; even input tiles, original output cropped to 2×. 67,073,434 bytes; 23-block RRDB, slower than ACNet.',
    ),
    V4ModelDef(
      id: 'realesrgan_x4plus',
      fileName: 'realesrgan_x4plus.onnx',
      displayName: 'RealESRGAN-x4plus (~67 MB, slower, general-purpose)',
      scale: 4,
      sizeHintMB: 67,
      defaultUrls: [
        'https://huggingface.co/SceneWorks/real-esrgan-onnx/resolve/09f741bac80a246b407da3ee902bf5f3291b602f/real_esrgan_x4.onnx',
      ],
      sha256Digest:
          '5c586662929cbc686c1a5c38d9c060dbdb4ea5863a1f7672b8c0761e6b89c033',
      sourceUrl: 'https://huggingface.co/SceneWorks/real-esrgan-onnx',
      licenseNote:
          'BSD-3-Clause. Weights: Xintao Wang / Real-ESRGAN; ONNX export: SceneWorks. Preserve copyright, license and disclaimer. Not manga-specialized; GAN may redraw details.',
      protocolNote:
          'esrgan: float32 [1,3,H,W] RGB 0..1 → [1,3,4H,4W]. 67,051,616 bytes; 23-block RRDB, slower with higher memory use. Not x4plus-anime-6B.',
    ),
  ];

  static const String _selectedModelKey = 'anime4kV4_selected_model';
  static String _selectedModelId = 'anime4k_acnet';
  static bool legacySelectionMigrated = false;

  static final ValueNotifier<ModelDownloadState?> downloadState =
      ValueNotifier<ModelDownloadState?>(null);
  static Future<void>? _downloadTask;

  static V4ModelDef _modelById(String id) =>
      models.firstWhere((m) => m.id == id, orElse: () => models.first);

  /// 当前选中模型的定义
  static V4ModelDef get selectedDef => _modelById(_selectedModelId);

  /// 当前选中模型的文件名（调用位置文件名）
  static String get modelFileName => selectedDef.fileName;

  /// 全部可用模型（供 UI 构建选择器）
  static List<V4ModelDef> getModels() => List.unmodifiable(models);

  static bool isValidModelId(String id) => models.any((m) => m.id == id);

  /// Retired preset had no working release. Never reuse its file or custom
  /// record as x2plus; those files remain untouched for explicit local import.
  static String migrateModelId(String id) {
    if (id != 'general_x2') return id;
    legacySelectionMigrated = true;
    return 'realesrgan_x2plus';
  }

  /// Persist the selected preset; installations and custom records stay isolated.
  static Future<void> setSelectedModelId(String id) async {
    id = migrateModelId(id);
    if (!isValidModelId(id)) return;
    _selectedModelId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, id);
  }

  /// Read mirror preferences for the captured model, including an empty list.
  static Future<List<String>> getModelUrls({V4ModelDef? model}) async {
    final def = model ?? selectedDef;
    final prefs = await SharedPreferences.getInstance();
    return List.from(
      prefs.getStringList('anime4kV4_urls_${def.id}') ?? def.defaultUrls,
    );
  }

  static Future<void> addModelUrl(String url) async {
    final def = selectedDef;
    final urls = await getModelUrls(model: def);
    final trimmed = url.trim();
    if (trimmed.isEmpty || urls.contains(trimmed)) return;
    urls.add(trimmed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('anime4kV4_urls_${def.id}', urls);
  }

  static Future<void> removeModelUrlAt(int index) async {
    final def = selectedDef;
    final urls = await getModelUrls(model: def);
    if (index < 0 || index >= urls.length) return;
    urls.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('anime4kV4_urls_${def.id}', urls);
  }

  static Future<void> resetModelUrls() async {
    final def = selectedDef;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('anime4kV4_urls_${def.id}');
  }

  static Future<bool> isCustomModelActive({V4ModelDef? model}) async {
    final def = model ?? selectedDef;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('anime4kV4_custom_${def.id}') ?? false) &&
        await ensureModelAvailable(model: def) != null;
  }

  static Future<String?> getCustomModelName() async {
    final def = selectedDef;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('anime4kV4_custom_name_${def.id}');
  }

  /// 回退到内置（下载）模型：删除被覆盖的模型调用位置文件，若存在此前备份则还原。
  static Future<void> clearCustomModelSelection() async {
    final def = selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final backup = File('$targetPath.bak');
    if (await backup.exists()) {
      await ImageAiService.instance.installStagedModel(
        backup.path,
        targetPath,
        'esrgan',
      );
    } else {
      await ImageAiService.instance.resetSession();
      final target = File(targetPath);
      if (await target.exists()) await target.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('anime4kV4_custom_${def.id}', false);
    await prefs.remove('anime4kV4_custom_name_${def.id}');
    await prefs.remove('anime4kV4_bundled_${def.id}');
    await extractBundledModelIfNeeded();
  }

  /// 标记“模型调用位置的文件”为自选外部模型（写 prefs + 刷新缓存路径）。
  static Future<void> markCustomModelActive(
    String displayName, {
    V4ModelDef? model,
  }) async {
    final def = model ?? selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    await ImageAiService.instance.getModelInfo(targetPath, 'esrgan');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('anime4kV4_custom_${def.id}', true);
    await prefs.setString('anime4kV4_custom_name_${def.id}', displayName);
  }

  /// Extract the bundled model once unless the user selected an external model
  /// or explicitly deleted this installation. Validate before publishing it.
  static Future<void> extractBundledModelIfNeeded() async {
    try {
      final def = selectedDef;
      // 用户自选外部模型时不覆盖
      if (await isCustomModelActive(model: def)) return;

      final prefs = await SharedPreferences.getInstance();
      final installedKey = 'anime4kV4_bundled_${def.id}';
      if (prefs.getBool(installedKey) ?? false) {
        // 已抽取过一次；若用户随后手动删除，不再自动回灌
        return;
      }

      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, def.fileName);
      final targetFile = File(targetPath);

      // An installed file is not overwritten, even when validation rejects it.
      if (await targetFile.exists()) {
        await ImageAiService.instance.getModelInfo(targetPath, 'esrgan');
        await prefs.setBool(installedKey, true);
        return;
      }

      // 未打包（2x 模型默认不打包）则静默跳过，交给下载管理器
      final assetPath = def.bundledAssetPath;
      if (assetPath == null) return;

      // 从 assets 读取打包模型；不存在（未打包）则静默跳过
      final ByteData data;
      try {
        data = await rootBundle.load(assetPath);
      } catch (_) {
        // assets 未包含该模型：交给下载管理器，保持可构建/可降级
        return;
      }

      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (bytes.isEmpty) {
        // 打包文件异常（过小），不写入，交给下载流程
        return;
      }

      // 原子写入：先写临时文件再重命名，避免中断产生半截文件
      final tmpPath = '$targetPath.bundle.tmp';
      final tmpFile = File(tmpPath);
      await tmpFile.writeAsBytes(bytes, flush: true);
      await ImageAiService.instance.installStagedModel(
        tmpPath,
        targetPath,
        'esrgan',
      );

      await prefs.setBool(installedKey, true);
      Log.info(
        'Anime4KV4',
        'bundled model (${def.id}) extracted to $targetPath (${bytes.length} bytes)',
      );
    } catch (e, s) {
      Log.error('Anime4KV4', 'extractBundledModelIfNeeded failed: $e\n$s');
      ImageAiService.instance.reportError(
        e,
        operation: 'Bundled super-resolution model unavailable',
      );
    }
  }

  /// 获取模型文件路径（即模型调用位置）。不自动下载；文件不存在或无效则返回 null。
  static Future<String?> ensureModelAvailable({V4ModelDef? model}) async {
    final def = model ?? selectedDef;
    final dir = await getApplicationSupportDirectory();
    final target = File(path.join(dir.path, def.fileName));
    return await target.exists() && await target.length() > 0
        ? target.path
        : null;
  }

  /// Whether a model file is installed; readiness requires native validation.
  static Future<bool> get isModelDownloaded async =>
      await ensureModelAvailable() != null;

  static Future<int> getDownloadedSize() async {
    final def = selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final targetFile = File(targetPath);
    if (!await targetFile.exists()) return 0;
    return await targetFile.length();
  }

  static double get downloadProgress => downloadState.value?.progress ?? 0;
  static bool get isDownloading => _downloadTask != null;
  static String? get currentStatus => downloadState.value?.message;

  /// Downloads independently of observers; concurrent callers share one task.
  static Future<void> downloadModel({
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) {
    final existing = _downloadTask;
    final def = selectedDef;
    final task =
        existing ??
        (_downloadTask = Future<void>.microtask(() => _downloadModel(def)));
    return forwardModelDownloadCallbacks(
      task,
      downloadState,
      onProgress: onProgress,
      onStatus: onStatus,
      replay: existing != null,
    );
  }

  static Future<void> _downloadModel(V4ModelDef def) async {
    var receivedBytes = 0;
    var totalBytes = 0;
    var message = 'Preparing download...';
    void report({String? status, bool active = true, String? error}) {
      if (status != null) message = status;
      downloadState.value = ModelDownloadState(
        modelId: def.id,
        modelName: def.displayName,
        message: message,
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        isDownloading: active,
        error: error,
      );
    }

    try {
      report();
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, def.fileName);
      final tempPath = '$targetPath.tmp';
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      Object? lastError;
      StackTrace? lastStack;
      final urls = await getModelUrls(model: def);
      for (int i = 0; i < urls.length; i++) {
        receivedBytes = 0;
        totalBytes = 0;
        report(status: 'Downloading from mirror ${i + 1}/${urls.length}...');
        try {
          await _downloadWithResume(urls[i], tempPath, (received, total) {
            receivedBytes = received;
            totalBytes = total;
            report();
          });
          final downloaded = await tempFile.length();
          if (downloaded == 0) {
            throw StateError('Empty model download');
          }
          if (def.sha256Digest != null) {
            report(status: 'Verifying SHA-256...');
            final digest = await ImageAiService.instance.modelIdentity(
              tempFile.path,
            );
            if (digest != def.sha256Digest) {
              throw StateError('Model SHA-256 mismatch');
            }
          }
          report(status: 'Validating and installing model...');
          await ImageAiService.instance.installStagedModel(
            tempPath,
            targetPath,
            'esrgan',
          );
          final oldBackup = File('$targetPath.bak');
          if (await oldBackup.exists()) await oldBackup.delete();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('anime4kV4_custom_${def.id}', false);
          await prefs.remove('anime4kV4_custom_name_${def.id}');
          receivedBytes = downloaded;
          totalBytes = downloaded;
          report(status: 'Download complete', active: false);
          return;
        } catch (error, stack) {
          lastError = error;
          lastStack = stack;
          report(status: 'Mirror ${i + 1} failed: $error');
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
      }
      if (lastError != null) {
        Error.throwWithStackTrace(lastError, lastStack!);
      }
      throw StateError('All model download URLs failed');
    } catch (error) {
      report(status: 'Download failed: $error', active: false, error: '$error');
      rethrow;
    } finally {
      _downloadTask = null;
    }
  }

  static Future<void> _downloadWithResume(
    String url,
    String targetPath,
    void Function(int received, int total) onProgress,
  ) async {
    final client = HttpClient();
    final file = File(targetPath);
    int startByte = 0;
    if (await file.exists()) {
      startByte = await file.length();
    }

    IOSink? sink;
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.headers.set('User-Agent', 'CManga/1.0');
      request.headers.set('Accept', '*/*');
      request.headers.set('Connection', 'keep-alive');
      if (startByte > 0) {
        request.headers.set('Range', 'bytes=$startByte-');
      }

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw Exception('HTTP ${response.statusCode}');
      }

      if (response.statusCode == HttpStatus.ok) startByte = 0;
      final contentLength = response.contentLength;
      int received = startByte;
      final total = contentLength > 0 ? contentLength + startByte : 0;

      sink = file.openWrite(
        mode: startByte > 0 ? FileMode.append : FileMode.write,
      );

      await sink.addStream(
        response.map((chunk) {
          received += chunk.length;
          onProgress(received, total);
          return chunk;
        }),
      );
      await sink.close();
    } catch (e) {
      await sink?.close();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 清除模型文件（含自选外部模型备份）
  static Future<void> clearModel() async {
    await ImageAiService.instance.resetSession();
    final def = selectedDef;
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final tempPath = '$targetPath.tmp';
    final bakPath = '$targetPath.bak';
    final targetFile = File(targetPath);
    final tempFile = File(tempPath);
    final bakFile = File(bakPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    if (await bakFile.exists()) {
      await bakFile.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('anime4kV4_custom_${def.id}', false);
    await prefs.remove('anime4kV4_custom_name_${def.id}');
    // An explicit deletion must also suppress first-use bundle extraction.
    await prefs.setBool('anime4kV4_bundled_${def.id}', true);
  }
}
