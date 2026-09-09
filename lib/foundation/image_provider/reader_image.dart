import 'dart:async' show Future, StreamController;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/image_ai_service.dart';
import 'package:venera/utils/anime4k/anime4k_service.dart';
import 'package:venera/utils/anime4k/anime4k_v4_service.dart';
import 'package:venera/utils/colorization/colorization_service.dart';
import 'package:venera/utils/processed_image_store.dart';
import 'reader_image_details.dart';

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page,
  );

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  @override
  Future<Uint8List> load(chunkEvents, checkStop, {Uint8List? sourceBytes}) =>
      _loadProcessed(
        chunkEvents,
        checkStop,
        requireComplete: false,
        sourceBytes: sourceBytes,
      );

  /// Export uses precisely the reader pipeline, never the original cache.
  Future<Uint8List> exportImage({Uint8List? sourceBytes}) async {
    final events = StreamController<ImageChunkEvent>.broadcast();
    try {
      return await _loadProcessed(
        events,
        () {},
        requireComplete: true,
        sourceBytes: sourceBytes,
      );
    } finally {
      await events.close();
    }
  }

  Future<Uint8List> _loadProcessed(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop, {
    required bool requireComplete,
    Uint8List? sourceBytes,
  }) async {
    // Snapshot before IO so a settings change cannot mix two pipelines.
    final aiSettings = <String, dynamic>{
      for (final setting in [
        'enableAnime4K',
        'anime4KVersion',
        'anime4KV4Intensity',
        'anime4KV4OutputScale',
        'anime4KEnhancementStrength',
        'imageAiBackend',
        'anime4KScaleFactor',
        'anime4KPushStrength',
        'anime4KPushGradStrength',
        'enableColorization',
        'colorizationIntensity',
      ])
        setting: appdata.settings.getReaderSetting(
          cid,
          sourceKey ?? 'local',
          setting,
        ),
      'enableCustomImageProcessing':
          appdata.settings['enableCustomImageProcessing'],
      'customImageProcessing': appdata.settings['customImageProcessing'],
    };
    final details = ReaderImageDetailsStore.instance;
    final record = details.begin(
      imageKey,
      sourceKey,
      cid,
      eid,
      page,
      values: {
        'Source': imageKey,
        'Page': '$page',
        'Super-resolution': aiSettings['enableAnime4K'] == true
            ? 'Waiting'
            : 'Disabled',
        'Colorization': aiSettings['enableColorization'] == true
            ? 'Waiting'
            : 'Disabled',
        'Engine Version': '${aiSettings['anime4KVersion']}',
        'Requested backend': '${aiSettings['imageAiBackend'] ?? 'auto'}',
        'Requested output scale': aiSettings['anime4KVersion'] == 'v4'
            ? '${aiSettings['anime4KV4OutputScale'] ?? 0} (0 = model scale)'
            : '${aiSettings['anime4KScaleFactor'] ?? 2}',
        'Super-resolution strength':
            '${((aiSettings['anime4KEnhancementStrength'] as num? ?? 1) * 100).round()}%',
        'AI output contrast': '${aiSettings['anime4KV4Intensity'] ?? 1}',
        'Colorization strength':
            '${((aiSettings['colorizationIntensity'] as num? ?? 1) * 100).round()}%',
      },
    );
    var cancelled = false;
    void checkActive() {
      try {
        checkStop();
      } catch (_) {
        cancelled = true;
        rethrow;
      }
    }

    try {
      if (imageKey.startsWith('file://') &&
          ProcessedImageStore.containsPath(imageKey.substring(7))) {
        throw StateError('Generated images are not source comic pages');
      }
      return await _process(
        chunkEvents,
        checkActive,
        aiSettings,
        record,
        requireComplete: requireComplete,
        sourceBytes: sourceBytes,
      );
    } catch (error) {
      details.update(
        record,
        state: cancelled ? 'Cancelled' : 'Failed',
        values: {'Error': error.toString()},
      );
      rethrow;
    }
  }

  Future<Uint8List> _process(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
    Map<String, dynamic> aiSettings,
    ReaderImageDetails record, {
    required bool requireComplete,
    Uint8List? sourceBytes,
  }) async {
    final details = ReaderImageDetailsStore.instance;
    double parameter(String key, double fallback) =>
        (aiSettings[key] as num?)?.toDouble() ?? fallback;
    final backend = aiSettings['imageAiBackend'] as String? ?? 'auto';
    Uint8List? imageBytes = sourceBytes;
    if (imageBytes == null) {
      if (imageKey.startsWith('file://')) {
        // Strip the "file://" prefix to get the actual file path.
        // LocalManager stores local image keys as "file://<absolutePath>",
        // so we must remove the scheme before constructing a [File].
        var file = File(imageKey.substring(7));
        if (await file.exists()) {
          imageBytes = await file.readAsBytes();
        } else {
          throw "Error: File not found.";
        }
      } else {
        await for (var event in ImageDownloader.loadComicImage(
          imageKey,
          sourceKey,
          cid,
          eid,
        )) {
          checkStop();
          chunkEvents.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: event.currentBytes,
              expectedTotalBytes: event.totalBytes,
            ),
          );
          if (event.imageBytes != null) {
            imageBytes = event.imageBytes;
            break;
          }
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    checkStop();
    String? originalSize;
    try {
      originalSize = await _dimensions(imageBytes);
    } catch (_) {
      // A source hook may decrypt or repair bytes before Flutter can decode them.
    }
    details.update(
      record,
      values: {
        'Original resolution': originalSize ?? 'Unknown',
        'Original encoded size': '${imageBytes.length} B',
      },
    );
    var bytes = imageBytes;
    if (aiSettings['enableCustomImageProcessing'] == true &&
        aiSettings['customImageProcessing'].toString().contains(
          'function processImage',
        )) {
      var script = aiSettings['customImageProcessing'].toString();
      var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
      if (func is JSInvokable) {
        var autoFreeFunc = JSAutoFreeFunction(func);
        var result = autoFreeFunc([bytes, cid, eid, page, sourceKey]);
        if (result is Uint8List) {
          bytes = result;
        } else if (result is Future) {
          var futureResult = await result;
          if (futureResult is Uint8List) {
            bytes = futureResult;
          }
        } else if (result is Map) {
          var image = result['image'];
          if (image is Uint8List) {
            bytes = image;
          } else if (image is Future) {
            JSAutoFreeFunction? onCancel;
            if (result['onCancel'] is JSInvokable) {
              onCancel = JSAutoFreeFunction(result['onCancel']);
            }
            if (onCancel == null) {
              var futureImage = await image;
              if (futureImage is Uint8List) {
                bytes = futureImage;
              }
            } else {
              dynamic futureImage;
              image.then((value) {
                futureImage = value;
                futureImage ??= Uint8List(0);
              });
              while (futureImage == null) {
                try {
                  checkStop();
                } catch (e) {
                  onCancel([]);
                  rethrow;
                }
                await Future.delayed(Duration(milliseconds: 50));
              }
              if (futureImage is Uint8List) {
                bytes = futureImage;
              }
            }
          }
        }
      }
    }
    checkStop();
    var finalSize = identical(bytes, imageBytes) && originalSize != null
        ? originalSize
        : await _dimensions(bytes);
    ImageAiStatus? incompleteStage;
    var srSucceeded = false;
    Future<void> persist(String stage, String label) async {
      if (!imageKey.startsWith('file://')) return;
      checkStop();
      try {
        final file = await ProcessedImageStore.save(
          sourcePath: imageKey.substring(7),
          stage: stage,
          bytes: bytes,
        );
        details.update(record, values: {label: file.path});
      } catch (error) {
        // Keep the readable result, but never claim a local write succeeded.
        details.update(record, values: {'Local save error': error.toString()});
        ImageAiService.instance.reportError(
          error,
          operation: 'Saving processed page failed',
        );
      }
    }

    if (aiSettings['enableAnime4K'] == true) {
      details.update(
        record,
        state: 'Processing',
        values: {
          'Super-resolution': 'Processing',
          'Before super-resolution': finalSize,
        },
      );
      final watch = Stopwatch()..start();
      ImageAiStatus? stageStatus;
      void onStatus(ImageAiStatus value) {
        stageStatus = value;
        details.update(
          record,
          values: {'Super-resolution execution': value.message},
        );
      }

      final strength = parameter('anime4KEnhancementStrength', 1.0);
      final Uint8List? enhanced;
      if (aiSettings['anime4KVersion'] == 'v4') {
        enhanced = await Anime4KV4Service.instance.processImage(
          imageBytes: bytes,
          cacheKey: key,
          intensity: parameter('anime4KV4Intensity', 1.0),
          outputScale: parameter('anime4KV4OutputScale', 0.0),
          strength: strength,
          backend: backend,
          onStatus: onStatus,
        );
      } else {
        enhanced = await Anime4KService.instance.processImage(
          imageBytes: bytes,
          cacheKey: key,
          scaleFactor: parameter('anime4KScaleFactor', 2.0),
          pushStrength: parameter('anime4KPushStrength', 0.31),
          pushGradStrength: parameter('anime4KPushGradStrength', 1.0),
          strength: strength,
          onStatus: onStatus,
        );
      }
      watch.stop();
      checkStop();
      details.update(
        record,
        values: {'Super-resolution elapsed': '${watch.elapsedMilliseconds} ms'},
      );
      if (enhanced != null) {
        bytes = enhanced;
        finalSize = await _dimensions(bytes);
        srSucceeded = true;
        details.update(
          record,
          values: {
            'Super-resolution': 'Succeeded',
            'After super-resolution': finalSize,
            'Super-resolution backend': stageStatus?.backend ?? 'unknown',
          },
        );
        await persist('super_resolution', 'Super-resolution file');
      } else {
        incompleteStage =
            stageStatus ??
            const ImageAiStatus(
              message: 'Super-resolution failed; no processed output',
              isError: true,
            );
        details.update(
          record,
          values: {
            'Super-resolution': 'Failed',
            'After super-resolution': 'No successful output',
            'Super-resolution error': incompleteStage.message,
          },
        );
      }
    }
    if (aiSettings['enableColorization'] == true) {
      details.update(
        record,
        state: 'Processing',
        values: {'Colorization': 'Processing'},
      );
      final watch = Stopwatch()..start();
      ImageAiStatus? stageStatus;
      final colored = await ColorizationService.instance.processImage(
        imageBytes: bytes,
        cacheKey: key,
        intensity: parameter('colorizationIntensity', 1.0),
        backend: backend,
        onStatus: (value) {
          stageStatus = value;
          details.update(
            record,
            values: {'Colorization execution': value.message},
          );
        },
      );
      watch.stop();
      checkStop();
      details.update(
        record,
        values: {'Colorization elapsed': '${watch.elapsedMilliseconds} ms'},
      );
      if (colored != null) {
        bytes = colored;
        finalSize = await _dimensions(bytes);
        details.update(
          record,
          values: {
            'Colorization': 'Succeeded',
            'Colorization backend': stageStatus?.backend ?? 'unknown',
          },
        );
        await persist(
          srSucceeded ? 'super_resolution_colorization' : 'colorization',
          srSucceeded ? 'Combined result file' : 'Colorization file',
        );
      } else {
        final failure =
            stageStatus ??
            const ImageAiStatus(
              message: 'Colorization failed; no processed output',
              isError: true,
            );
        incompleteStage ??= failure;
        details.update(
          record,
          values: {
            'Colorization': 'Failed',
            'Colorization error': failure.message,
          },
        );
      }
    }
    details.update(
      record,
      state: incompleteStage == null ? 'Complete' : 'Incomplete',
      values: {
        'Final resolution': finalSize,
        'Final encoded size': '${bytes.length} B',
      },
    );
    if (incompleteStage != null) {
      ImageAiService.instance.status.value = incompleteStage;
      if (requireComplete) throw StateError(incompleteStage.message);
    }
    return bytes;
  }

  Future<String> _dimensions(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return '${descriptor.width} × ${descriptor.height}';
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "$imageKey@$sourceKey@$cid@$eid";

  @override
  bool get enableResize => false;
}
