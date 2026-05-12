import '../core/constants/genres.dart';

/// Coarse quality bucket for the cover-quality warning chip.
///
/// Ordering matches severity: a hard warn always outranks a soft warn.
/// The chip uses [ok] as a "hide" sentinel.
enum CoverQualityLevel { ok, softWarn, hardWarn }

/// Result of [assessCoverQuality]: a severity bucket + a short reason
/// suitable for a chip label (≤ ~30 chars).
class CoverQualityAssessment {
  final CoverQualityLevel level;
  final String reason;
  const CoverQualityAssessment(this.level, this.reason);

  static const CoverQualityAssessment ok =
      CoverQualityAssessment(CoverQualityLevel.ok, '');
}

/// Effective render scale per source pixel: how big each source pixel
/// becomes in the exported 1024×2048 texture.  Mirrors the math in
/// [ImagePreparer.encode] (cover-fit max-of-two-ratios, then * zoom).
///
/// > 1.0 means upscaling (quality loss).  ≤ 1.0 is downscale, lossless
/// for our purposes since DXT1 + mip generation dominates anyway.
double effectiveScale({
  required int imageWidth,
  required int imageHeight,
  required double zoom,
  int canvasWidth = kTextureBkgWidth,
  int canvasHeight = kTextureBkgHeight,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return 0;
  final sX = canvasWidth / imageWidth;
  final sY = canvasHeight / imageHeight;
  final baseScale = sX > sY ? sX : sY;
  return baseScale * zoom;
}

/// Fraction of the 1024×2048 canvas covered by the source image at the
/// given transform — 1.0 means every output pixel comes from the source,
/// values below 1.0 mean some part of the canvas exports as black.
///
/// Pure geometry: cover-fit places the source centred on the canvas,
/// then offsetX/offsetY shifts it.  At zoom < 1.0 the image is smaller
/// than the canvas and the gutters expose black; at zoom ≥ 1.0 only an
/// aggressive offset can push enough of the image off-canvas to expose
/// black corners.
double canvasCoverage({
  required int imageWidth,
  required int imageHeight,
  required double zoom,
  required int offsetX,
  required int offsetY,
  int canvasWidth = kTextureBkgWidth,
  int canvasHeight = kTextureBkgHeight,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return 0;
  final scale = effectiveScale(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    zoom: zoom,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  );
  final rW = imageWidth * scale;
  final rH = imageHeight * scale;
  final dstX = (canvasWidth - rW) / 2 + offsetX;
  final dstY = (canvasHeight - rH) / 2 + offsetY;
  final x1 = dstX < 0 ? 0.0 : dstX;
  final y1 = dstY < 0 ? 0.0 : dstY;
  final x2 = (dstX + rW) > canvasWidth ? canvasWidth.toDouble() : (dstX + rW);
  final y2 =
      (dstY + rH) > canvasHeight ? canvasHeight.toDouble() : (dstY + rH);
  final coveredW = x2 > x1 ? x2 - x1 : 0.0;
  final coveredH = y2 > y1 ? y2 - y1 : 0.0;
  return (coveredW * coveredH) / (canvasWidth * canvasHeight);
}

// Thresholds tuned per design briefing §6.3 + §10.2: "warning chip when
// the image is being scaled past its native resolution and quality will
// suffer".  Defaults err on the cautious side — most user covers are
// 600-1500px wide, which sits squarely in the soft-warn band.
const double _kUpscaleSoft = 1.5; // image rendered ≥ 1.5× native
const double _kUpscaleHard = 3.0; // ≥ 3× native — looks blurry in-game
const double _kCoverageSoft = 0.98; // > 2 % of canvas exports as black
const double _kCoverageHard = 0.80; // > 20 % black — clearly broken

/// Assess whether the cover transform will produce a visibly degraded
/// in-game texture.  Pure function; widget-free so the same call drives
/// the chip in the editor AND can be used in tests / future build-time
/// linting.
///
/// Most-severe condition wins (hard > soft > ok).  Reason string is what
/// the chip displays; keep it ≤ 30 chars.
CoverQualityAssessment assessCoverQuality({
  required int imageWidth,
  required int imageHeight,
  required double zoom,
  required int offsetX,
  required int offsetY,
  int canvasWidth = kTextureBkgWidth,
  int canvasHeight = kTextureBkgHeight,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return CoverQualityAssessment.ok;

  final scale = effectiveScale(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    zoom: zoom,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  );
  final coverage = canvasCoverage(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    zoom: zoom,
    offsetX: offsetX,
    offsetY: offsetY,
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
  );

  // Hard-warn first — either condition alone is enough.
  if (scale >= _kUpscaleHard) {
    return CoverQualityAssessment(
      CoverQualityLevel.hardWarn,
      'Heavy upscale ${scale.toStringAsFixed(1)}×',
    );
  }
  if (coverage < _kCoverageHard) {
    final pct = ((1 - coverage) * 100).round();
    return CoverQualityAssessment(
      CoverQualityLevel.hardWarn,
      '$pct% of canvas empty',
    );
  }
  if (scale >= _kUpscaleSoft) {
    return CoverQualityAssessment(
      CoverQualityLevel.softWarn,
      'Upscaled ${scale.toStringAsFixed(1)}×',
    );
  }
  if (coverage < _kCoverageSoft) {
    final pct = ((1 - coverage) * 100).round();
    return CoverQualityAssessment(
      CoverQualityLevel.softWarn,
      '$pct% of canvas empty',
    );
  }
  return CoverQualityAssessment.ok;
}
