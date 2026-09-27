import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cmanga/utils/image_ai_service.dart';
import 'package:cmanga/utils/model_download.dart';

/// A model's explicit native pipeline, installation and publishing provenance.
class ColorizationModelVariant {
  final String id;
  final String label;
  final String type;
  final String fileName;
  final int? sizeBytes;
  final List<String> defaultUrls;
  final String sourceUrl;
  final String licenseNote;
  final String protocolNote;
  final String? sha256Digest;
  final bool requiresNonCommercialConsent;

  const ColorizationModelVariant({
    required this.id,
    required this.label,
    required this.type,
    required this.fileName,
    required this.defaultUrls,
    required this.sourceUrl,
    required this.licenseNote,
    required this.protocolNote,
    this.sizeBytes,
    this.sha256Digest,
    this.requiresNonCommercialConsent = false,
  });

  bool get canDownload => defaultUrls.isNotEmpty;
}

/// Models are streamed at runtime, validated with their native pipeline, and
/// installed independently. No large weights are included in Flutter assets.
class ColorizationModelManager {
  static const _variantKey = 'colorization_model_variant';
  static const _migrationKey = 'colorization_independent_models_v1';
  static Future<void>? _initialization;
  static String _selectedVariant = 'deoldify';
  static final ValueNotifier<ModelDownloadState?> downloadState =
      ValueNotifier<ModelDownloadState?>(null);
  static Future<void>? _downloadTask;

  static const List<ColorizationModelVariant> modelVariants = [
    ColorizationModelVariant(
      id: 'deoldify',
      label: 'DeOldify Artistic',
      type: 'deoldify',
      fileName: 'deoldify_artistic.onnx',
      sizeBytes: 243 * 1024 * 1024,
      defaultUrls: [
        'https://mirror.ghproxy.com/https://github.com/instant-high/deoldify-onnx/releases/download/deoldify-onnx/deoldify.onnx',
        'https://ghp.ci/https://github.com/instant-high/deoldify-onnx/releases/download/deoldify-onnx/deoldify.onnx',
        'https://ghproxy.net/https://github.com/instant-high/deoldify-onnx/releases/download/deoldify-onnx/deoldify.onnx',
        'https://github.com/instant-high/deoldify-onnx/releases/download/deoldify-onnx/deoldify.onnx',
      ],
      sourceUrl: 'https://github.com/instant-high/deoldify-onnx',
      licenseNote:
          'Existing DeOldify distribution; check the publisher and upstream license before redistribution.',
      protocolNote:
          'deoldify: float32 NCHW RGB 0..255 → RGB; original luminance and size retained.',
    ),
    ColorizationModelVariant(
      id: 'deoldify-int8',
      label: 'DeOldify int8 (轻量, 实验性)',
      type: 'deoldify',
      fileName: 'deoldify_int8.onnx',
      defaultUrls: [
        'https://ghproxy.net/https://github.com/Kiastr/AiColorize/releases/download/models/deoldify_int8.onnx',
        'https://github.com/Kiastr/AiColorize/releases/download/models/deoldify_int8.onnx',
      ],
      sourceUrl: 'https://github.com/Kiastr/AiColorize/releases/tag/models',
      licenseNote:
          'Existing experimental int8 distribution; check the publisher and upstream license before redistribution.',
      protocolNote:
          'deoldify: compatible RGB input/output wrapper required; int8 describes internal quantization, not a different pipeline.',
    ),
    ColorizationModelVariant(
      id: 'anime_deoldify',
      label: 'AnimeColorDeOldify Grayscale2Color (~423 MB)',
      type: 'anime_deoldify',
      fileName: 'anime_grayscale2color_rgb256.onnx',
      sizeBytes: 422934355,
      defaultUrls: [
        'https://github.com/cliecy/CManga/releases/download/image-ai-models-20260909/anime_grayscale2color_rgb256.onnx',
      ],
      sourceUrl: 'https://github.com/Dakini/AnimeColorDeOldify',
      licenseNote:
          'Dakini states MIT for its trained weights. ONNX converted from the original Grayscale2Color checkpoint; conversion provenance and license accompany the model release.',
      protocolNote:
          'anime_deoldify: fixed float32 RGB 0..255 at 256² with original normalization inside the graph. App preserves original Lab L, alpha and size; not a pixel-identical reproduction of the upstream YUV filters.',
      sha256Digest:
          'ca4f7bcf44775c8586e6ae2fe353cccb160a62214f37f02c6fb87525eaf62aa3',
    ),
    ColorizationModelVariant(
      id: 'ddcolor',
      label: 'DDColor Artistic (~980 MB)',
      type: 'ddcolor',
      fileName: 'ddcolor_artistic.onnx',
      sizeBytes: 980103562,
      defaultUrls: [
        'https://huggingface.co/facefusion/models-3.0.0/resolve/728b9659bd9691bf32cbf7f61af478d94b7ba81e/ddcolor_artistic.onnx',
        'https://github.com/facefusion/facefusion-assets/releases/download/models-3.0.0/ddcolor_artistic.onnx',
      ],
      sourceUrl: 'https://huggingface.co/facefusion/models-3.0.0',
      licenseNote:
          'DDColor by piddnad: Apache-2.0. ONNX published by FaceFusion; its aggregate repository does not declare a separate export license. Large model: high memory use.',
      protocolNote:
          'ddcolor: 256² neutral Lab-derived RGB 0..1 → 2-channel float Lab ab; retain original L, alpha and dimensions.',
      sha256Digest:
          'adad4b897990d627e139e858e8a6552c1f99e39e49e811d21e8f591803c877f1',
    ),
    ColorizationModelVariant(
      id: 'manga_light',
      label: 'Manga Light Colorizer V6 — generator only (~191 MB)',
      type: 'manga_light',
      fileName: 'manga_light.onnx',
      sizeBytes: 191335312,
      defaultUrls: [
        'https://huggingface.co/sharky172/manga-light-colorizer/resolve/2fb022c4ce55632b7671a1df306f63984928e36a/models/v6_generator.onnx',
      ],
      sourceUrl: 'https://huggingface.co/sharky172/manga-light-colorizer',
      licenseNote:
          'CC BY-NC-SA 4.0: attribution, non-commercial use only, adaptations under the same license. Publisher: sharky172. Generator-only automatic mode; no SAM or WD14 semantic guidance.',
      protocolNote:
          'manga_light: 512² grayscale [-1,1], zero sam_level0 [1,256,32,32], sam_level1 [1,256,16,16] and wd14_embedding [1,1024] → RGB [-1,1]; retain original L, alpha and dimensions.',
      sha256Digest:
          '48284fcf0b7a606270702630f559af88eecf95bc6cdec1ff8bce8663d12b4bb6',
      requiresNonCommercialConsent: true,
    ),
    ColorizationModelVariant(
      id: 'manga_v2',
      label: 'Manga Colorization v2 — local import (~61 MB)',
      type: 'manga_v2',
      fileName: 'manga_v2.onnx',
      sizeBytes: 61650260,
      defaultUrls: [],
      sourceUrl: 'https://huggingface.co/Faridzar/manga-colorization-v2-onnx',
      licenseNote:
          'Local import only. Faridzar labels its ONNX MIT, but qweasdd/manga-colorization-v2 has no verified upstream weight license. Commercial use and redistribution are not cleared.',
      protocolNote:
          'manga_v2: float32 [1,5,H,W], first RGB channel 0..1 and four zero hint/mask channels → RGB 0..1. Fit long edge 512 and pad to multiples of 32; retain original L, alpha and dimensions.',
    ),
  ];

  static ColorizationModelVariant _definition(String id) =>
      modelVariants.firstWhere(
        (model) => model.id == id,
        orElse: () => throw ArgumentError('Unknown colorization model: $id'),
      );

  static String _key(String kind, ColorizationModelVariant model) =>
      'colorization_${kind}_${model.id}';

  static Future<void> _initialize() => _initialization ??= _loadSelection();

  static Future<void> _loadSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_variantKey) ?? 'deoldify';
    _selectedVariant = modelVariants.any((model) => model.id == saved)
        ? saved
        : 'deoldify';
    if (prefs.getBool(_migrationKey) ?? false) return;
    // The old two variants shared a single compatible DeOldify pipeline/file.
    // Preserve that installation and its custom backup under the saved variant.
    final legacy = _definition(saved == 'deoldify-int8' ? saved : 'deoldify');
    final dir = await getApplicationSupportDirectory();
    if (legacy.id == 'deoldify-int8') {
      for (final suffix in ['', '.bak']) {
        final oldFile = File(
          path.join(dir.path, 'deoldify_artistic.onnx$suffix'),
        );
        final destination = File(
          path.join(dir.path, '${legacy.fileName}$suffix'),
        );
        if (await oldFile.exists() && !await destination.exists()) {
          await ImageAiService.instance.resetSession();
          await oldFile.rename(destination.path);
        }
      }
    }
    final custom = prefs.getBool('colorization_custom_model_active');
    if (custom != null) await prefs.setBool(_key('custom', legacy), custom);
    final name = prefs.getString('colorization_custom_model_name');
    if (name != null) await prefs.setString(_key('custom_name', legacy), name);
    final urls = prefs.getStringList('colorization_model_urls');
    if (urls != null) {
      await prefs.setStringList(_key('urls', modelVariants.first), urls);
    }
    await prefs.setBool(_migrationKey, true);
  }

  static Future<ColorizationModelVariant> getSelectedDefinition() async {
    await _initialize();
    return _definition(_selectedVariant);
  }

  static Future<String> getSelectedVariant() async =>
      (await getSelectedDefinition()).id;

  static Future<void> setSelectedVariant(String id) async {
    _definition(id);
    await _initialize();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_variantKey, id);
    _selectedVariant = id;
  }

  static Future<List<String>> getModelUrls({
    ColorizationModelVariant? model,
  }) async {
    final def = model ?? await getSelectedDefinition();
    if (!def.canDownload) return [];
    final prefs = await SharedPreferences.getInstance();
    return List.from(prefs.getStringList(_key('urls', def)) ?? def.defaultUrls);
  }

  static Future<void> addModelUrl(String url) async {
    final def = await getSelectedDefinition();
    if (!def.canDownload) {
      throw StateError('This model supports local import only');
    }
    final urls = await getModelUrls(model: def);
    final trimmed = url.trim();
    if (trimmed.isEmpty || urls.contains(trimmed)) return;
    urls.add(trimmed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key('urls', def), urls);
  }

  static Future<void> removeModelUrlAt(int index) async {
    final def = await getSelectedDefinition();
    final urls = await getModelUrls(model: def);
    if (index < 0 || index >= urls.length) return;
    urls.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key('urls', def), urls);
  }

  static Future<void> resetModelUrls() async {
    final def = await getSelectedDefinition();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key('urls', def));
  }

  static Future<bool> isCustomModelActive({
    ColorizationModelVariant? model,
  }) async {
    final def = model ?? await getSelectedDefinition();
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_key('custom', def)) ?? false) &&
        await ensureModelAvailable(model: def) != null;
  }

  static Future<String?> getCustomModelName({
    ColorizationModelVariant? model,
  }) async {
    final def = model ?? await getSelectedDefinition();
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key('custom_name', def));
  }

  static Future<void> _clearCustomRecord(ColorizationModelVariant def) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('custom', def), false);
    await prefs.remove(_key('custom_name', def));
  }

  static Future<void> clearCustomModelSelection() async {
    final def = await getSelectedDefinition();
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    final backup = File('$targetPath.bak');
    if (await backup.exists()) {
      await ImageAiService.instance.installStagedModel(
        backup.path,
        targetPath,
        def.type,
      );
    } else {
      await ImageAiService.instance.resetSession();
      final target = File(targetPath);
      if (await target.exists()) await target.delete();
    }
    await _clearCustomRecord(def);
  }

  static Future<void> markCustomModelActive(
    String displayName, {
    ColorizationModelVariant? model,
  }) async {
    final def = model ?? await getSelectedDefinition();
    final dir = await getApplicationSupportDirectory();
    await ImageAiService.instance.getModelInfo(
      path.join(dir.path, def.fileName),
      def.type,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key('custom', def), true);
    await prefs.setString(_key('custom_name', def), displayName);
  }

  /// Installed is distinct from ready: native getModelInfo validates the graph.
  static Future<String?> ensureModelAvailable({
    ColorizationModelVariant? model,
  }) async {
    final def = model ?? await getSelectedDefinition();
    final dir = await getApplicationSupportDirectory();
    final target = File(path.join(dir.path, def.fileName));
    return await target.exists() && await target.length() > 0
        ? target.path
        : null;
  }

  static Future<bool> get isModelDownloaded async =>
      await ensureModelAvailable() != null;

  static Future<int> getDownloadedSize() async {
    final targetPath = await ensureModelAvailable();
    return targetPath == null ? 0 : File(targetPath).length();
  }

  static double get downloadProgress => downloadState.value?.progress ?? 0;
  static bool get isDownloading => _downloadTask != null;
  static String? get currentStatus => downloadState.value?.message;

  /// Concurrent callers observe the running model, not a second transfer.
  static Future<void> downloadModel({
    String? variant,
    bool nonCommercialAccepted = false,
    void Function(double progress)? onProgress,
    void Function(String status)? onStatus,
  }) {
    final existing = _downloadTask;
    final Future<void> task;
    if (existing != null) {
      task = existing;
    } else {
      final requestedId = variant ?? _selectedVariant;
      final Future<ColorizationModelVariant> Function() definition =
          variant == null
          ? getSelectedDefinition
          : () async => _definition(variant);
      task = _downloadTask = Future<void>.microtask(
        () => _downloadModel(definition, requestedId, nonCommercialAccepted),
      );
    }
    return forwardModelDownloadCallbacks(
      task,
      downloadState,
      onProgress: onProgress,
      onStatus: onStatus,
      replay: existing != null,
    );
  }

  static Future<void> _downloadModel(
    Future<ColorizationModelVariant> Function() definition,
    String requestedId,
    bool nonCommercialAccepted,
  ) async {
    ColorizationModelVariant? capturedDef;
    var receivedBytes = 0;
    var totalBytes = 0;
    var message = 'Preparing download...';
    void report({String? status, bool active = true, String? error}) {
      if (status != null) message = status;
      downloadState.value = ModelDownloadState(
        modelId: capturedDef?.id ?? requestedId,
        modelName: capturedDef?.label ?? requestedId,
        message: message,
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
        isDownloading: active,
        error: error,
      );
    }

    try {
      report();
      final def = await definition();
      capturedDef = def;
      report();
      if (!def.canDownload) {
        throw StateError(
          'This model supports local import only: upstream license unresolved',
        );
      }
      if (def.requiresNonCommercialConsent && !nonCommercialAccepted) {
        throw StateError(
          'CC BY-NC-SA 4.0 non-commercial license acceptance required',
        );
      }
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(dir.path, def.fileName);
      final tempFile = File('$targetPath.tmp');
      if (await tempFile.exists()) await tempFile.delete();
      Object? lastError;
      StackTrace? lastStack;
      final urls = await getModelUrls(model: def);
      for (var i = 0; i < urls.length; i++) {
        receivedBytes = 0;
        totalBytes = 0;
        report(status: 'Downloading from mirror ${i + 1}/${urls.length}...');
        try {
          await _downloadWithResume(urls[i], tempFile.path, (received, total) {
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
            tempFile.path,
            targetPath,
            def.type,
          );
          final oldBackup = File('$targetPath.bak');
          if (await oldBackup.exists()) await oldBackup.delete();
          await _clearCustomRecord(def);
          receivedBytes = downloaded;
          totalBytes = downloaded;
          report(status: 'Download complete', active: false);
          return;
        } catch (error, stack) {
          lastError = error;
          lastStack = stack;
          report(status: 'Mirror ${i + 1} failed: $error');
          if (await tempFile.exists()) await tempFile.delete();
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
    var startByte = await file.exists() ? await file.length() : 0;
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      request.headers.set('User-Agent', 'CManga/1.0');
      request.headers.set('Accept', '*/*');
      if (startByte > 0) request.headers.set('Range', 'bytes=$startByte-');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.statusCode == HttpStatus.ok) startByte = 0;
      var received = startByte;
      final total = response.contentLength > 0
          ? response.contentLength + startByte
          : 0;
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
    } catch (_) {
      await sink?.close();
      rethrow;
    } finally {
      client.close();
    }
  }

  static Future<void> clearModel() async {
    final def = await getSelectedDefinition();
    await ImageAiService.instance.resetSession();
    final dir = await getApplicationSupportDirectory();
    final targetPath = path.join(dir.path, def.fileName);
    for (final suffix in ['', '.tmp', '.bak']) {
      final file = File('$targetPath$suffix');
      if (await file.exists()) await file.delete();
    }
    await _clearCustomRecord(def);
  }
}
