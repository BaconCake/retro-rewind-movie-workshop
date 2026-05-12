import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/domain/cover_quality.dart';

/// Pure-helper tests for the cover-quality warning chip.  The thresholds
/// matter: they decide whether a chip appears on the editor and what
/// colour it shows.  Anchoring the boundaries against representative
/// covers keeps a future threshold tweak from silently changing UX.
void main() {
  group('effectiveScale', () {
    test('perfect 1024×2048 portrait at zoom=1 → 1.0', () {
      expect(
        effectiveScale(imageWidth: 1024, imageHeight: 2048, zoom: 1.0),
        closeTo(1.0, 1e-9),
      );
    });

    test('large 2048×4096 source at zoom=1 → 0.5 (downscale)', () {
      expect(
        effectiveScale(imageWidth: 2048, imageHeight: 4096, zoom: 1.0),
        closeTo(0.5, 1e-9),
      );
    });

    test('tiny 200×400 source at zoom=1 → ~5.12 (heavy upscale)', () {
      expect(
        effectiveScale(imageWidth: 200, imageHeight: 400, zoom: 1.0),
        closeTo(5.12, 1e-9),
      );
    });

    test('zoom multiplies the cover-scale', () {
      // 1024×2048 (cover-scale 1.0) at zoom=2.0 → 2.0
      expect(
        effectiveScale(imageWidth: 1024, imageHeight: 2048, zoom: 2.0),
        closeTo(2.0, 1e-9),
      );
    });

    test('non-1:2 source picks max-of-two ratios (cover-fit)', () {
      // 1024×1024 square: width matches canvas, height needs 2× → cover = 2
      expect(
        effectiveScale(imageWidth: 1024, imageHeight: 1024, zoom: 1.0),
        closeTo(2.0, 1e-9),
      );
    });

    test('zero/negative dims return 0 (defensive)', () {
      expect(
          effectiveScale(imageWidth: 0, imageHeight: 100, zoom: 1.0), 0);
      expect(
          effectiveScale(imageWidth: 100, imageHeight: 0, zoom: 1.0), 0);
    });
  });

  group('canvasCoverage', () {
    test('perfect-fit cover-zoom 1.0 with no offset → 1.0', () {
      expect(
        canvasCoverage(
          imageWidth: 1024,
          imageHeight: 2048,
          zoom: 1.0,
          offsetX: 0,
          offsetY: 0,
        ),
        closeTo(1.0, 1e-9),
      );
    });

    test('square source still fully covers (cover-fit fills H, overhangs W)',
        () {
      // 1024×1024 → renders 2048×2048, centred, overhanging X by 512 each side
      expect(
        canvasCoverage(
          imageWidth: 1024,
          imageHeight: 1024,
          zoom: 1.0,
          offsetX: 0,
          offsetY: 0,
        ),
        closeTo(1.0, 1e-9),
      );
    });

    test('zoom=0.5 leaves 75% of canvas empty', () {
      // image rendered at half size — only 1/4 of canvas area covered
      expect(
        canvasCoverage(
          imageWidth: 1024,
          imageHeight: 2048,
          zoom: 0.5,
          offsetX: 0,
          offsetY: 0,
        ),
        closeTo(0.25, 1e-9),
      );
    });

    test('extreme positive offset pushes image off-canvas', () {
      // 1024×2048 source at zoom=1 starts fully covering canvas.  Offset
      // by half the canvas in X shifts the image right by 512 → only the
      // left half of canvas is covered → coverage = 0.5.
      expect(
        canvasCoverage(
          imageWidth: 1024,
          imageHeight: 2048,
          zoom: 1.0,
          offsetX: 512,
          offsetY: 0,
        ),
        closeTo(0.5, 1e-9),
      );
    });

    test('zoom=2.0 source overhangs canvas in all directions → coverage 1.0',
        () {
      expect(
        canvasCoverage(
          imageWidth: 1024,
          imageHeight: 2048,
          zoom: 2.0,
          offsetX: 0,
          offsetY: 0,
        ),
        closeTo(1.0, 1e-9),
      );
    });
  });

  group('assessCoverQuality', () {
    test('perfect-fit 1024×2048 at zoom=1 → ok', () {
      final a = assessCoverQuality(
        imageWidth: 1024,
        imageHeight: 2048,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.ok);
    });

    test('large 4000×8000 source at zoom=1 → ok (heavy downscale)', () {
      final a = assessCoverQuality(
        imageWidth: 4000,
        imageHeight: 8000,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.ok);
    });

    test('mild upscale 700×1400 (~1.46×) sits just below soft threshold', () {
      final a = assessCoverQuality(
        imageWidth: 700,
        imageHeight: 1400,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      // 1024/700 ≈ 1.463 < 1.5 → ok
      expect(a.level, CoverQualityLevel.ok);
    });

    test('600×1200 source (~1.71×) → soft warn', () {
      final a = assessCoverQuality(
        imageWidth: 600,
        imageHeight: 1200,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.softWarn);
      expect(a.reason, contains('1.7'));
    });

    test('300×600 source (~3.4×) → hard warn', () {
      final a = assessCoverQuality(
        imageWidth: 300,
        imageHeight: 600,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.hardWarn);
      expect(a.reason, contains('3.4'));
    });

    test('heavy user zoom on a good source still triggers hard warn', () {
      // 1024×2048 source at zoom=3.5 → effective scale 3.5 → hard warn
      final a = assessCoverQuality(
        imageWidth: 1024,
        imageHeight: 2048,
        zoom: 3.5,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.hardWarn);
    });

    test('low coverage from low zoom → soft warn', () {
      // zoom=0.9 with no offset → coverage = 0.81 → soft warn
      final a = assessCoverQuality(
        imageWidth: 1024,
        imageHeight: 2048,
        zoom: 0.9,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.softWarn);
      expect(a.reason, contains('empty'));
    });

    test('very low coverage → hard warn', () {
      // zoom=0.5 → coverage = 0.25 → hard warn
      final a = assessCoverQuality(
        imageWidth: 1024,
        imageHeight: 2048,
        zoom: 0.5,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.hardWarn);
      expect(a.reason, contains('empty'));
    });

    test('hard upscale wins over soft coverage warn (most-severe rule)', () {
      // 300×600 source: 3.4× upscale.  Coverage at zoom=1 is 1.0 because
      // cover-fit fills the canvas — so the upscale wins anyway, but the
      // assertion makes the precedence explicit if defaults change.
      final a = assessCoverQuality(
        imageWidth: 300,
        imageHeight: 600,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.hardWarn);
      expect(a.reason, contains('×'));
    });

    test('zero dims → ok (no spurious chip while dims are loading)', () {
      final a = assessCoverQuality(
        imageWidth: 0,
        imageHeight: 0,
        zoom: 1.0,
        offsetX: 0,
        offsetY: 0,
      );
      expect(a.level, CoverQualityLevel.ok);
    });
  });
}
