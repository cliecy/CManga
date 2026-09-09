import 'dart:async' show Future;
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
  Future<Uint8List> load(chunkEvents, checkStop) async {
    // Snapshot per-comic settings before IO. A refresh creates a new request;
    // this request must not mix old SR parameters with new color parameters.
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
          sourceKey ?? '',
          setting,
        ),
    };
    double parameter(String key, double fallback) =>
        (aiSettings[key] as num?)?.toDouble() ?? fallback;
    final backend = aiSettings['imageAiBackend'] as String? ?? 'auto';
    Uint8List? imageBytes;
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
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    // 自此 imageBytes 非 null，用 final 捕获以便下方闭包/赋值使用
    var bytes = imageBytes;
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return bytes;
      }
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
    // Always run super-resolution before colorization. Missing/unsupported AI
    // keeps the readable image and an explicit failure, never a v1 fallback.
    ImageAiStatus? incompleteStage;
    if (aiSettings['enableAnime4K'] == true) {
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
        );
      } else {
        enhanced = await Anime4KService.instance.processImage(
          imageBytes: bytes,
          cacheKey: key,
          scaleFactor: parameter('anime4KScaleFactor', 2.0),
          pushStrength: parameter('anime4KPushStrength', 0.31),
          pushGradStrength: parameter('anime4KPushGradStrength', 1.0),
          strength: strength,
        );
      }
      if (enhanced != null) {
        bytes = enhanced;
      } else {
        incompleteStage = ImageAiService.instance.status.value;
      }
    }
    if (aiSettings['enableColorization'] == true) {
      final colored = await ColorizationService.instance.processImage(
        imageBytes: bytes,
        cacheKey: key,
        intensity: parameter('colorizationIntensity', 1.0),
        backend: backend,
      );
      if (colored != null) bytes = colored;
      // A successful later stage must not advertise the whole page as complete.
      if (incompleteStage != null) {
        ImageAiService.instance.status.value = incompleteStage;
      }
    }

    return bytes;
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
