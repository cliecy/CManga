import 'package:flutter_test/flutter_test.dart';
import 'package:cmanga/pages/reader/image_adjustments.dart';

void main() {
  group('readerAdjustmentMatrix', () {
    test('neutral values produce no filter at all', () {
      expect(readerAdjustmentMatrix(), isNull);
      expect(
          readerAdjustmentMatrix(
              brightness: kNeutralBrightness,
              contrast: kNeutralContrast,
              saturation: kNeutralSaturation),
          isNull);
    });

    test('pure brightness adds an offset to RGB only', () {
      var m = readerAdjustmentMatrix(brightness: 0.5)!;
      // Column-major 4x5: [R' col, G' col, B' col, A' col], each column is
      // (coeffR, coeffG, coeffB, coeffA, offset). Diagonals sit at 0/6/12.
      expect(m[0], 1); // R' ← R
      expect(m[6], 1); // G' ← G
      expect(m[12], 1); // B' ← B
      expect(m[4], closeTo(127.5, 0.001)); // offset = 0.5 * 255
      expect(m[9], closeTo(127.5, 0.001));
      expect(m[14], closeTo(127.5, 0.001));
      // Off-diagonals vanish at neutral saturation/contrast.
      expect(m[1], 0);
      expect(m[2], 0);
      expect(m[5], 0);
      expect(m[7], 0);
      // Alpha untouched.
      expect(m.sublist(15), [0, 0, 0, 1, 0]);
    });

    test('saturation 0 is classic luma grayscale', () {
      var m = readerAdjustmentMatrix(saturation: 0)!;
      // R' = 0.299R + 0.587G + 0.114B (and same for G'/B').
      expect(m[0], closeTo(0.299, 1e-9));
      expect(m[1], closeTo(0.587, 1e-9));
      expect(m[2], closeTo(0.114, 1e-9));
      expect(m[3], 0);
      expect(m[4], closeTo(0, 1e-9)); // no offset at neutral contrast/brightness
      expect(m[5], closeTo(0.299, 1e-9));
      expect(m[6], closeTo(0.587, 1e-9));
    });

    test('contrast 2 doubles around mid-gray', () {
      var m = readerAdjustmentMatrix(contrast: 2)!;
      expect(m[0], closeTo(2, 1e-9)); // R' = 2R - 128
      expect(m[4], closeTo(-128, 1e-9));
      expect(m[6], closeTo(2, 1e-9));
      expect(m[12], closeTo(2, 1e-9));
    });
    test('combined values stay finite and alpha stays identity', () {
      var m = readerAdjustmentMatrix(brightness: -1, contrast: 0.3, saturation: 1.8)!;
      for (var v in m) {
        expect(v.isFinite, isTrue);
      }
      expect(m.sublist(15), [0, 0, 0, 1, 0]);
    });
  });
}
