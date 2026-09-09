import 'dart:async' show Future, StreamController, scheduleMicrotask, unawaited;
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static double? _effectiveScreenWidth;

  static const double _normalComicImageRatio = 0.72;

  static const double _minComicImageWidth = 1920 * _normalComicImageRatio;

  static TargetImageSize _getTargetSize(width, height) {
    if (_effectiveScreenWidth == null) {
      final screens = PlatformDispatcher.instance.displays;
      for (var screen in screens) {
        if (screen.size.width > screen.size.height) {
          _effectiveScreenWidth = max(
            _effectiveScreenWidth ?? 0,
            screen.size.height * _normalComicImageRatio,
          );
        } else {
          _effectiveScreenWidth = max(
            _effectiveScreenWidth ?? 0,
            screen.size.width,
          );
        }
      }
      if (_effectiveScreenWidth! < _minComicImageWidth) {
        _effectiveScreenWidth = _minComicImageWidth;
      }
    }
    if (width > _effectiveScreenWidth!) {
      height = (height * _effectiveScreenWidth! / width).round();
      width = _effectiveScreenWidth!.round();
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final loading = CancelableCompleter<ui.Codec>();
    chunkEvents.onCancel = () {
      // Stream completion is not cancellation; only an abandoned consumer stops work.
      if (!chunkEvents.isClosed) unawaited(loading.operation.cancel());
    };
    unawaited(
      _loadBufferAsync(
        key,
        chunkEvents,
        decode,
        () => loading.isCanceled,
      ).then<void>((codec) {
        if (loading.isCanceled) {
          codec.dispose();
        } else {
          loading.complete(codec);
        }
      }, onError: loading.completeError),
    );
    return MultiFrameImageStreamCompleter(
      codec: loading.operation.value,
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    bool Function() shouldStop,
  ) async {
    try {
      int retryTime = 1;

      Uint8List? data;

      while (data == null && !shouldStop()) {
        try {
          data = await load(chunkEvents, () {
            if (shouldStop()) {
              throw const _ImageLoadingStopException();
            }
          });
        } on _ImageLoadingStopException {
          rethrow;
        } catch (e) {
          if (e.toString().contains("Invalid Status Code: 404")) {
            rethrow;
          }
          if (e.toString().contains("Invalid Status Code: 403")) {
            rethrow;
          }
          if (e.toString().contains("handshake")) {
            if (retryTime < 5) {
              retryTime = 5;
            }
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3) || shouldStop()) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: retryTime));
        }
      }

      if (shouldStop()) {
        throw const _ImageLoadingStopException();
      }

      if (data!.isEmpty) {
        throw Exception("Empty image data");
      }

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        return await decode(
          buffer,
          getTargetSize: enableResize ? _getTargetSize : null,
        );
      } catch (e) {
        await CacheManager().delete(this.key);
        if (data.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text = const Utf8Codec(
              allowMalformed: false,
            ).decoder.convert(data);
            throw Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        rethrow;
      }
    } on _ImageLoadingStopException {
      rethrow;
    } catch (e, s) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Log.error("Image Loading", e, s);
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}
