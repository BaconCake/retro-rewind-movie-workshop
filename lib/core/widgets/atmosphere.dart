/// Always-on ambient layer (LN-3): faint scanlines + a pink/cyan radial
/// wash painted behind every screen.  Drop [AmbientBackground] once at
/// the Scaffold body level; it self-paints + IgnorePointer's so input
/// never hits it.
///
/// [ScanlineOverlay] is exposed separately for inner surfaces that want
/// their own CRT feel (cover preview canvas, build log, hero areas).
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Subtle horizontal scanline overlay.  Stack over any child, or wrap
/// individual surfaces.  Intensity 0.0–1.0 — 0.03 is the default and
/// reads as just-perceptible on a calibrated dark display.
class ScanlineOverlay extends StatelessWidget {
  final double intensity;
  final double spacing; // px between line pairs
  const ScanlineOverlay({
    super.key,
    this.intensity = 0.03,
    this.spacing = 3,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ScanlinePainter(intensity, spacing),
        ),
      );
}

class _ScanlinePainter extends CustomPainter {
  final double intensity;
  final double spacing;
  _ScanlinePainter(this.intensity, this.spacing);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: intensity);
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) =>
      old.intensity != intensity || old.spacing != spacing;
}

/// Ambient app background.  Magenta wash at the top, cyan wash at the
/// bottom, both very faint; a hairline scanline veil over the whole
/// viewport.  Goes underneath every screen — wrap the topmost Scaffold
/// body with `AmbientBackground(child: …)`.
class AmbientBackground extends StatelessWidget {
  final Widget child;
  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          // Pink wash — anchored above the viewport so the gradient
          // peaks just inside the top edge.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -1.2),
                radius: 0.9,
                colors: [
                  kColorPink.withValues(alpha: 0.06),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          // Cyan wash — anchored below the viewport, mirrors the pink.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, 1.4),
                radius: 0.9,
                colors: [
                  kColorCyan.withValues(alpha: 0.04),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
          const Positioned.fill(
            child: ScanlineOverlay(intensity: 0.012, spacing: 3),
          ),
          child,
        ],
      );
}
