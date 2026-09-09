import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:venera/utils/anime4k/anime4k_upscaler.dart';

/// Tests for the Anime4K super-resolution component.
///
/// These tests verify the pure-Dart Anime4K implementation without relying on
/// Flutter widgets, ONNX models, or isolate infrastructure. They focus on the
/// core algorithm contract: given valid image bytes, the upscaler must produce
/// a larger, decodable PNG whose dimensions match the requested scale factor.
void main() {
  group('Anime4KUpscaler.processDirect', () {
    test('upscales a small RGB image by the given scale factor', () {
      final src = img.Image(width: 8, height: 8, numChannels: 4);
      // Draw a simple pattern: left half dark, right half bright.
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          if (x < 4) {
            src.setPixelRgba(x, y, 20, 20, 20, 255);
          } else {
            src.setPixelRgba(x, y, 230, 230, 230, 255);
          }
        }
      }

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
        pushStrength: 0.31,
        pushGradStrength: 1.0,
      );

      final result = Anime4KUpscaler.processDirect(params);

      expect(result, isNotNull);
      expect(result!.isNotEmpty, true);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      // 8 * 2.0 = 16
      expect(decoded!.width, 16);
      expect(decoded.height, 16);
    });

    test('returns null for invalid image bytes', () {
      final params = Anime4KParams(
        imageBytes: Uint8List.fromList([0, 1, 2, 3, 4]),
        scaleFactor: 2.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNull);
    });

    test('respects scaleFactor parameter (1.0 keeps size)', () {
      final src = img.Image(width: 10, height: 6, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(100, 150, 200, 255));

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 1.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 10);
      expect(decoded.height, 6);
    });

    test('preserves alpha channel in output', () {
      final src = img.Image(width: 6, height: 6, numChannels: 4);
      // Half transparent, half opaque.
      for (int y = 0; y < 6; y++) {
        for (int x = 0; x < 6; x++) {
          final alpha = x < 3 ? 0 : 255;
          src.setPixelRgba(x, y, 200, 100, 50, alpha);
        }
      }

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(decoded.width - 1, 0).a, 255);
    });
  });

  group('Anime4KUpscaler.processInIsolate', () {
    test('produces the requested dimensions in a worker isolate', () async {
      final src = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(180, 180, 180, 255));

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
      );

      final result = await Anime4KUpscaler.processInIsolate(params);
      expect(result, isNotNull);
      expect(result!.isNotEmpty, true);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      expect(decoded!.width, 16);
      expect(decoded.height, 16);
    });
  });

  group('independent enhancement strength', () {
    test(
      'half strength mixes in linear light, not by changing contrast',
      () async {
        final source = img.Image(width: 1, height: 1, numChannels: 4);
        final enhanced = img.Image(width: 1, height: 1, numChannels: 4);
        source.setPixelRgba(0, 0, 0, 0, 0, 255);
        enhanced.setPixelRgba(0, 0, 255, 255, 255, 255);
        final result = await Anime4KUpscaler.renderInIsolate(
          Anime4KRenderParams(
            imageBytes: Uint8List.fromList(img.encodePng(source)),
            enhancedBytes: Uint8List.fromList(img.encodePng(enhanced)),
            scaleFactor: 1,
            strength: .5,
          ),
        );
        final pixel = img.decodePng(result)!.getPixel(0, 0);
        expect(pixel.r, closeTo(188, 1));
        expect(pixel.g, closeTo(188, 1));
        expect(pixel.b, closeTo(188, 1));
        expect(pixel.a, 255);
      },
    );

    test(
      'zero strength resizes odd dimensions without an enhanced image',
      () async {
        final source = img.Image(width: 7, height: 11, numChannels: 4);
        img.fill(source, color: img.ColorRgba8(50, 100, 150, 255));
        final result = await Anime4KUpscaler.renderInIsolate(
          Anime4KRenderParams(
            imageBytes: Uint8List.fromList(img.encodePng(source)),
            scaleFactor: 1.3,
            strength: 0,
          ),
        );
        final decoded = img.decodePng(result)!;
        expect((decoded.width, decoded.height), (9, 14));
        expect(decoded.getPixel(4, 7).r, closeTo(50, 1));
        expect(decoded.getPixel(4, 7).g, closeTo(100, 1));
        expect(decoded.getPixel(4, 7).b, closeTo(150, 1));
      },
    );

    test(
      'transparent hidden colors do not bleed into the visible edge',
      () async {
        final source = img.Image(width: 2, height: 1, numChannels: 4);
        source.setPixelRgba(0, 0, 255, 0, 0, 0);
        source.setPixelRgba(1, 0, 0, 0, 255, 255);
        final result = await Anime4KUpscaler.renderInIsolate(
          Anime4KRenderParams(
            imageBytes: Uint8List.fromList(img.encodePng(source)),
            scaleFactor: 2,
            strength: 0,
          ),
        );
        final decoded = img.decodePng(result)!;
        for (final pixel in decoded) {
          if (pixel.a > 0) {
            expect(pixel.r, 0);
            expect(pixel.g, 0);
            expect(pixel.b, closeTo(255, 1));
          }
        }
      },
    );
  });
}
