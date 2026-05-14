import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/genres.dart';

/// Pins `layoutOverlayPlacement` to the exact values produced by Python's
/// in-canvas math (RR_VHS_Tool.py:12822-12842) for each of the 5 layouts.
/// Expected values derived from `lscale = (bg_bot - bg_top) / (window.bottom
/// - window.top)` evaluated against the same kLayoutFit / kLayoutWindows /
/// kLayoutOvlNudge tables — if either side drifts the diff will fail loud.
void main() {
  group('layoutOverlayPlacement parity with Python', () {
    test('layout 1 — wide window, HIDDEN_LEFT align', () {
      // lscale = 1592 / 1279 = 1.2447224394057857
      final p = layoutOverlayPlacement(1)!;
      expect(p.loy, closeTo(-93.2275215011728, 1e-9));
      expect(p.lox, closeTo(-109.65363564885378, 1e-6));
      expect(p.scaledSize, closeTo(2549.1915559030494, 1e-9));
    });
    test('layout 2 — narrow window, right-aligned', () {
      // lscale = 1600 / 1279 = 1.2509773260359656
      // window_w = 797 * lscale = 997.03 < 1024  → right-align
      final p = layoutOverlayPlacement(2)!;
      expect(p.loy, closeTo(-380.3205629397967, 1e-9));
      expect(p.lox, closeTo(-117.38936669272869, 1e-6));
      expect(p.scaledSize, closeTo(2562.0015637216575, 1e-6));
    });
    test('layout 3 — same window as 2, different fit_top', () {
      final p = layoutOverlayPlacement(3)!;
      expect(p.loy, closeTo(-379.3205629397967, 1e-9));
      expect(p.lox, closeTo(-117.38936669272869, 1e-6));
      expect(p.scaledSize, closeTo(2562.0015637216575, 1e-6));
    });
    test('layout 4 — narrow window, no nudge', () {
      // lscale = 1623 / 1356 = 1.1969026548672566
      // window_w = 852 * lscale = 1019.76 < 1024  → right-align
      final p = layoutOverlayPlacement(4)!;
      expect(p.loy, closeTo(-56.25442477876106, 1e-9));
      expect(p.lox, closeTo(-98.69469026548658, 1e-6));
      expect(p.scaledSize, closeTo(2451.2566371681415, 1e-9));
    });
    test('layout 5 — wide window, narrower than layout 1', () {
      final p = layoutOverlayPlacement(5)!;
      expect(p.loy, closeTo(-93.2275215011728, 1e-9));
      expect(p.lox, closeTo(-109.65363564885378, 1e-6));
      expect(p.scaledSize, closeTo(2549.1915559030494, 1e-9));
    });
    test('returns null for invalid layouts', () {
      expect(layoutOverlayPlacement(0), isNull);
      expect(layoutOverlayPlacement(-1), isNull);
      expect(layoutOverlayPlacement(6), isNull);
      expect(layoutOverlayPlacement(99), isNull);
    });
  });

  group('display-pixel projection', () {
    test('display projection scales linearly with canvas width', () {
      // At a canvas matching the bg-texture width (1024 px), display
      // coords are identical to bg-texture coords.  This is the
      // identity case the painter is checked against.
      final p = layoutOverlayPlacement(1)!;
      const canvasWidth = 1024.0;
      final texToScreen = canvasWidth / kTextureBkgWidth;
      expect(texToScreen, 1.0);
      expect(p.lox * texToScreen, closeTo(p.lox, 1e-12));
      expect(p.scaledSize * texToScreen, closeTo(p.scaledSize, 1e-12));
    });
    test('at half canvas width, every coord halves', () {
      final p = layoutOverlayPlacement(2)!;
      const canvasWidth = 512.0;
      final texToScreen = canvasWidth / kTextureBkgWidth;
      expect(p.lox * texToScreen, closeTo(p.lox / 2, 1e-9));
      expect(p.loy * texToScreen, closeTo(p.loy / 2, 1e-9));
      expect(p.scaledSize * texToScreen, closeTo(p.scaledSize / 2, 1e-9));
    });
  });
}
