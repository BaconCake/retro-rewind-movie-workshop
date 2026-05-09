/// Per-shape geometry of an NR standee, in 1024×2048 texture pixels.
/// Pure port of `STANDEE_ZONES` from RR_VHS_Tool.py:1029-1041.
///
/// Used by the cropper overlay to draw:
///   * a gold dashed line at [frontEnd] (top of title plate)
///   * a dimmer gold dashed line at [titleEnd] (top of footer / base)
///   * a dark-brown dashed line at [footerEnd] (frame cutoff, optional)
///   * thin vertical guides at [plateLeft] / [plateRight]
///   * fold lines at [foldLeft] / [foldRight] (Standee B only)
///   * a semicircular arch at ([archCenterY], [archRadius]) (Standee A)
///   * quarter-circle corner arcs of radius [cornerRadius] (Standee C)
///
/// All Y values are in [0..2048] texture-Y space; X values are in
/// [0..1024] texture-X space — same coordinate system as the bg texture.
library;

/// Texture height (pixels) — kept as a local for the [StandeeZones]
/// default expressions below.  Matches the global `kTextureBkgHeight`.
const int _texH = 2048;

class StandeeZones {
  /// Y of the boundary between the cover face and the title plate.
  final int frontEnd;

  /// Y of the boundary between the title plate and the footer / base.
  final int titleEnd;

  /// Y of the boundary at the bottom of the visible frame.  Defaults to
  /// the texture height when the standee shows the whole bottom edge.
  final int footerEnd;

  /// Texture pixels cropped from the left/right plate edges (zero when
  /// the standee shows the full width).
  final int plateLeft;
  final int plateRight;

  /// Standee B fold-back amount on each side (0 when not applicable).
  final int foldLeft;
  final int foldRight;

  /// Standee A semicircle arch.  centerY is the Y of the arc's centre,
  /// radius is the same value in X and Y texture pixels.  Both 0 when
  /// not applicable.
  final int archCenterY;
  final int archRadius;

  /// Standee C rounded-corner radius (in texture pixels).  0 when not
  /// applicable.
  final int cornerRadius;

  /// Standee B paints frame-colour on the footer band only.
  final bool footerBorderOnly;

  /// Standee C: title plate on the standee renders below the footer,
  /// not above it.  Drives a label tweak in the cropper overlay.
  final bool titleBelowFooter;

  const StandeeZones({
    required this.frontEnd,
    required this.titleEnd,
    this.footerEnd = _texH,
    this.plateLeft = 0,
    this.plateRight = 0,
    this.foldLeft = 0,
    this.foldRight = 0,
    this.archCenterY = 0,
    this.archRadius = 0,
    this.cornerRadius = 0,
    this.footerBorderOnly = false,
    this.titleBelowFooter = false,
  });
}

/// `STANDEE_ZONES` (RR_VHS_Tool.py:1029-1041) in Dart.
const Map<String, StandeeZones> kStandeeZones = {
  // Dome arch.  Semicircle at (texW/2, 256), radius 256.
  'A': StandeeZones(
    frontEnd: 1687,
    titleEnd: 1910,
    footerEnd: 2006,
    plateLeft: 35,
    plateRight: 35,
    archCenterY: 256,
    archRadius: 256,
  ),
  // Flat with sides folding backward; frame colour wraps the footer only.
  'B': StandeeZones(
    frontEnd: 1635,
    titleEnd: 1867,
    footerEnd: 2003,
    foldLeft: 100,
    foldRight: 100,
    footerBorderOnly: true,
  ),
  // Rounded corners at the top; title shown below footer on the standee.
  'C': StandeeZones(
    frontEnd: 1723,
    titleEnd: 1867,
    footerEnd: 2020,
    plateLeft: 75,
    plateRight: 75,
    cornerRadius: 100,
    titleBelowFooter: true,
  ),
};

/// Convenience: look up zones for a shape, fall back to A on unknown
/// inputs (matches Python's `STANDEE_ZONES.get(shape, STANDEE_ZONES["A"])`).
StandeeZones standeeZonesFor(String? shape) {
  if (shape == null) return kStandeeZones['A']!;
  return kStandeeZones[shape] ?? kStandeeZones['A']!;
}
