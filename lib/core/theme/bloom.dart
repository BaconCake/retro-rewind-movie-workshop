/// Reusable shadow lists for the "Late Night Rental" glow system (LN-2).
///
/// Rule: every glow in the app references one of these constants.  Never
/// hand-roll BoxShadow / Shadow lists in widget code — if a needed
/// variant doesn't exist here, add it here first.
///
/// `bloomSoft` / `Standard` / `Strong` are layer counts, not size — pick
/// the layer count that matches the visual weight (soft = idle / advisory,
/// standard = selected / hovered, strong = hero brand moments only).
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Soft halo — for idle states that need to lightly glow.
/// Examples: focused input outline, sort-pill on hover, status pill.
List<BoxShadow> bloomSoft(Color color) => [
      BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 8),
    ];

/// Standard bloom — for selected items and hovered CTAs.
/// Examples: hovered primary button, selected card outline.
List<BoxShadow> bloomStandard(Color color) => [
      BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 12),
      BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 32),
    ];

/// Strong bloom — for hero / brand moments only (rare).
/// Example: Ship-to-Store CTA on hover.
List<BoxShadow> bloomStrong(Color color) => [
      BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 14),
      BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 36),
      BoxShadow(color: color.withValues(alpha: 0.15), blurRadius: 80),
    ];

// ── Pre-baked common-case shorthand ──────────────────────────────────
// Functions (not constants) because the bloom lists hold computed
// `withValues` Colors, which aren't const-constructible.  Cheap to call
// repeatedly — Flutter doesn't re-render unless the shadow list shape
// actually changes per frame.

List<BoxShadow> get kBloomCyanSoft => bloomSoft(kColorCyan);
List<BoxShadow> get kBloomCyan => bloomStandard(kColorCyan);
List<BoxShadow> get kBloomPinkSoft => bloomSoft(kColorPink);
List<BoxShadow> get kBloomPink => bloomStandard(kColorPink);
List<BoxShadow> get kBloomAmber => bloomSoft(kColorWarn);
List<BoxShadow> get kBloomLime => bloomSoft(kColorShipped);
List<BoxShadow> get kBloomGold => bloomSoft(kColorGold);

// ── Text-shadow variants ─────────────────────────────────────────────
// Same colour-driven glow but emitted as `Shadow` rather than
// `BoxShadow` — apply via `TextStyle(shadows: ...)`.  Used by the
// brand wordmark (multi-layer) and by code-as-data values where a
// subtler single-layer glow reads better than a full bloom.

/// Two-layer text glow — apply via `TextStyle(shadows: ...)`.
/// [strength] scales both layers' alpha (1.0 = full, 0.5 = halved).
List<Shadow> textBloom(Color color, {double strength = 1.0}) => [
      Shadow(color: color.withValues(alpha: 0.7 * strength), blurRadius: 8),
      Shadow(color: color.withValues(alpha: 0.4 * strength), blurRadius: 24),
    ];

/// Single-layer text glow — quieter than [textBloom], for inline
/// values that should hint at a glow without competing with adjacent
/// text.
List<Shadow> textBloomSubtle(Color color) => [
      Shadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
    ];
