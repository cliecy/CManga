/// Display-layer image adjustments for the reader (brightness, contrast,
/// saturation), combined into a single [ColorFilter.matrix] payload.
library;
const double kNeutralBrightness = 0; // additive offset in [-1, 1]
const double kNeutralContrast = 1; // multiplicative around mid-gray
const double kNeutralSaturation = 1; // 0 = grayscale

/// Builds the 4x5 column-major matrix for [ColorFilter.matrix] combining
/// brightness (additive), contrast (around mid-gray) and saturation.
/// Returns null when every value is neutral so callers can skip adding a
/// paint layer entirely.
List<double>? readerAdjustmentMatrix({
  double brightness = kNeutralBrightness,
  double contrast = kNeutralContrast,
  double saturation = kNeutralSaturation,
}) {
  if (brightness == kNeutralBrightness &&
      contrast == kNeutralContrast &&
      saturation == kNeutralSaturation) {
    return null;
  }

  // Saturation: mix each channel toward luma (BT.601 weights).
  final s = saturation;
  final wR = 0.299 * (1 - s);
  final wG = 0.587 * (1 - s);
  final wB = 0.114 * (1 - s);

  // Contrast in 0..255 space: c*R + (1-c)*128.
  final co = 128 * (1 - contrast);

  // Pipeline order: saturation → contrast → additive brightness.
  final b = brightness * 255;
  final offset = co + b;
  return [
    contrast * (s + wR), contrast * wG, contrast * wB, 0, offset, // R'
    contrast * wR, contrast * (s + wG), contrast * wB, 0, offset, // G'
    contrast * wR, contrast * wG, contrast * (s + wB), 0, offset, // B'
    0, 0, 0, 1, 0, // A'
  ];
}
