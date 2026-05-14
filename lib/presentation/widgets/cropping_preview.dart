import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/constants/standee_zones.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/cover_actions.dart';
import '../providers/providers.dart';
import 'cover_image.dart';

/// Live cropper preview — port of the drag/zoom interaction on Python's
/// preview canvas (RR_VHS_Tool.py:7927-7949 + 11104-11290 + 11502-11530).
///
/// Behaviour:
///   * Click + drag (left mouse) on the cover → updates `offsetX` /
///     `offsetY` in **texture pixels** (1024×2048 space).
///   * Mouse-wheel scroll → adjusts `zoom` in 0.05 steps (clamped 0.25–4.0).
///   * Pan/zoom updates fire onPreview() during the gesture (live), and
///     onCommit() once at gesture end (persist to JSON).
///
/// The preview math matches `prepare_image()` exactly (RR_VHS_Tool.py:5542-5556):
/// the image is scaled to "cover" the canvas, then multiplied by `zoom`,
/// then translated by `(offsetX, offsetY)` from centre.
class CroppingPreview extends StatefulWidget {
  /// Image file to display. May not exist yet on disk — the widget falls
  /// back to a placeholder via [onMissing].
  final File file;

  /// Saved transform from `replacements.json`.
  final int savedOffsetX;
  final int savedOffsetY;
  final double savedZoom;

  /// Layout style (1..5) of the slot the image is cropped for.  Drives the
  /// safe-area / hidden-zone overlays via [layoutVisibleRect].  Values
  /// outside 1..5 fall back to the layout-agnostic kHidden* bands.
  final int layout;

  /// Live update during drag/scroll (every frame).
  final void Function(int offsetX, int offsetY, double zoom)? onPreview;

  /// Persistent commit at gesture end. Called with the final values when
  /// the user releases the mouse / stops scrolling for one tick.
  final void Function(int offsetX, int offsetY, double zoom) onCommit;

  /// Called when the file does not exist at build time.
  final WidgetBuilder onMissing;

  /// Bumped by the parent after an in-place file rewrite (e.g. ↻ Rotate) so
  /// the cached `Image.file` is rebuilt against the freshly written bytes
  /// instead of the stale image-cache entry.
  final int imageGeneration;

  /// Source image natural pixel dimensions.  Required for Pythons render
  /// math; the parent reads them from `imageDimensionsProvider` and shows
  /// a placeholder while the future is loading instead of mounting this
  /// widget without dims.
  final int imageWidth;
  final int imageHeight;

  /// When true, drags snap to safe-area centre / edges and canvas edges
  /// (40-px radius in canvas-coords).  Read from `snapEnabledProvider` by
  /// the parent.
  final bool snapEnabled;

  /// When true, the safe-area overlay (red hatched hidden zones + cyan
  /// dashed visible-area border) is painted on the canvas.  Snap guides
  /// are unaffected — they show on snap-to-centre regardless of this
  /// flag, matching Pythons `_show_snap_guides` (RR_VHS_Tool.py:11450).
  /// Parent reads `layoutOverlayProvider` and passes it here.
  final bool showOverlay;

  /// When non-null, paint the NR standee zone lines (gold/brown
  /// title-plate / footer / frame) for this shape.  Mutually exclusive
  /// with the layout-style overlay above — NRs cover the full canvas
  /// and don't have a layout-1..5 visible area.  See
  /// `lib/core/constants/standee_zones.dart` for geometry.
  final String? nrShape;

  /// When true (and [nrShape] is set), also paint the shape-specific
  /// overlay: semicircle arch for A, vertical fold lines for B,
  /// quarter-circle corner arcs for C.  Driven from `standeePreviewModeProvider`.
  final bool standeeMode;

  const CroppingPreview({
    super.key,
    required this.file,
    required this.savedOffsetX,
    required this.savedOffsetY,
    required this.savedZoom,
    required this.layout,
    required this.imageWidth,
    required this.imageHeight,
    required this.onCommit,
    required this.onMissing,
    this.onPreview,
    this.imageGeneration = 0,
    this.snapEnabled = true,
    this.showOverlay = false,
    this.nrShape,
    this.standeeMode = false,
  });

  @override
  State<CroppingPreview> createState() => _CroppingPreviewState();
}

class _CroppingPreviewState extends State<CroppingPreview> {
  // Live (uncommitted) transform during drag / scroll. Falls back to the
  // saved values when not actively editing.
  int? _liveX;
  int? _liveY;
  double? _liveZoom;

  // True between onPanStart and onPanEnd.  While set, we ignore any
  // savedOffsetX/Y prop changes — the parent mirrors our own onPreview
  // values back as `saved*`, and reacting to those would break the
  // `newX = savedOffsetX + accum` math by double-applying the delta.
  bool _isPanning = false;

  // Live snap-to-centre flags during drag — drive the cyan dashed guide
  // lines on the safe-area centre axis (RR_VHS_Tool.py:11450-11502).
  bool _centerSnapX = false;
  bool _centerSnapY = false;

  // Drag accounting in texture-pixel space (we accumulate fractional
  // remainders so small mouse moves don't get lost to integer rounding).
  double _dragAccumX = 0;
  double _dragAccumY = 0;

  // ── Viewport state (4e.3-4e.5) ───────────────────────────────────────
  // Pythons `_viewport_zoom` / `_viewport_pan_x/y` (RR_VHS_Tool.py:7943,
  // 11765).  These scale and translate the entire canvas display — image
  // + safe-area overlays included — without touching the saved per-slot
  // crop transform.  Reset to defaults when the slot changes (the parent
  // `_CoverEditorBlock` carries a ValueKey on `slot.bkgTex`, so we get
  // remounted with fresh state).
  double _vzoom = 1.0;
  double _vpanX = 0;
  double _vpanY = 0;
  bool _vPanning = false;
  double _vPanStartScreenX = 0;
  double _vPanStartScreenY = 0;
  double _vPanOrigX = 0;
  double _vPanOrigY = 0;

  @override
  void didUpdateWidget(covariant CroppingPreview old) {
    super.didUpdateWidget(old);
    // Never disturb live state mid-pan: the saved props are echoing our
    // own preview output and resetting _live here would compound the drag.
    if (_isPanning) return;
    if (_liveX == null && _liveY == null && _liveZoom == null) return;
    if (old.savedOffsetX != widget.savedOffsetX ||
        old.savedOffsetY != widget.savedOffsetY ||
        old.savedZoom != widget.savedZoom) {
      _liveX = null;
      _liveY = null;
      _liveZoom = null;
    }
  }

  int get _x => _liveX ?? widget.savedOffsetX;
  int get _y => _liveY ?? widget.savedOffsetY;
  double get _zoom => _liveZoom ?? widget.savedZoom;

  void _onPanStart(DragStartDetails _) {
    _dragAccumX = 0;
    _dragAccumY = 0;
    _isPanning = true;
    // Pin the saved values at gesture start so accum-based math stays
    // stable even if the parent echoes our preview output back.
    _panBaseX = widget.savedOffsetX;
    _panBaseY = widget.savedOffsetY;
    setState(() {
      _liveX = widget.savedOffsetX;
      _liveY = widget.savedOffsetY;
      _liveZoom = widget.savedZoom;
    });
  }

  // Snapshot of saved offset at pan start — the source of truth for
  // `newX = base + accum` so the math doesn't double-count parent echoes.
  int _panBaseX = 0;
  int _panBaseY = 0;

  void _onPanUpdate(DragUpdateDetails d, Size displaySize) {
    // Drag deltas come in display-pixel space. Convert to texture-pixel
    // space by dividing by the display→texture ratio AND the current
    // viewport zoom — at vz>1 the canvas is rendered larger so each
    // mouse pixel covers fewer canvas pixels (RR_VHS_Tool.py:11140-11150
    // uses `scale_x = TEX_WIDTH / dw` where `dw = base_dw * vz`).
    final scale = displaySize.width / kTextureBkgWidth * _vzoom;
    _dragAccumX += d.delta.dx / scale;
    _dragAccumY += d.delta.dy / scale;
    var newX = _panBaseX + _dragAccumX.round();
    var newY = _panBaseY + _dragAccumY.round();

    var centerSnapX = false;
    var centerSnapY = false;
    if (widget.snapEnabled &&
        widget.imageWidth > 0 &&
        widget.imageHeight > 0) {
      final s = applyDragSnap(
        rawOffsetX: newX,
        rawOffsetY: newY,
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
        zoom: _zoom,
        layout: widget.layout,
      );
      newX = s.offsetX;
      newY = s.offsetY;
      centerSnapX = s.centerSnapX;
      centerSnapY = s.centerSnapY;
    }

    setState(() {
      _liveX = newX;
      _liveY = newY;
      _centerSnapX = centerSnapX;
      _centerSnapY = centerSnapY;
    });
    widget.onPreview?.call(newX, newY, _zoom);
  }

  void _onPanEnd(DragEndDetails _) {
    final x = _x, y = _y, z = _zoom;
    _isPanning = false;
    setState(() {
      // Drop the snap guides as soon as the user releases — Pythons
      // `_show_snap_guides` likewise only paints them while the drag is
      // live (RR_VHS_Tool.py:11450-11458).
      _centerSnapX = false;
      _centerSnapY = false;
    });
    // Keep _live populated so the next build still shows the dragged
    // position; it gets cleared in didUpdateWidget once the parent's
    // commit lands and saved* equals what we just sent.
    widget.onCommit(x, y, z);
  }

  // Wheel = viewport zoom (RR_VHS_Tool.py:7820-7860).  Pythons binding
  // is wheel-on-canvas ↔ `_viewport_zoom`, NOT the saved image zoom; the
  // image zoom is reachable only via the slider / +/− buttons in the
  // editor bar.  Zoom snaps toward the mouse position so the canvas
  // point under the cursor stays put.
  void _onScroll(PointerSignalEvent e, Size displaySize) {
    if (e is! PointerScrollEvent) return;
    final dir = e.scrollDelta.dy > 0 ? -1 : 1;
    final next = (((_vzoom + dir * 0.1) * 100).round() / 100).clamp(0.25, 4.0);
    if (next == _vzoom) return;

    // Zoom toward the cursor (Pythons rel-x/rel-y math).
    final mx = e.localPosition.dx - displaySize.width / 2;
    final my = e.localPosition.dy - displaySize.height / 2;
    final oldDw = displaySize.width * _vzoom;
    final oldDh = displaySize.height * _vzoom;
    final relX = oldDw == 0 ? 0.0 : (mx - _vpanX) / oldDw;
    final relY = oldDh == 0 ? 0.0 : (my - _vpanY) / oldDh;
    final newDw = displaySize.width * next;
    final newDh = displaySize.height * next;
    var nx = mx - relX * newDw;
    var ny = my - relY * newDh;
    // Snap pan to 0 at vz=1 — Pythons does the same to stop tiny float
    // drifts from accumulating across many wheel ticks.
    if ((next - 1.0).abs() < 1e-6) {
      nx = 0;
      ny = 0;
    }
    setState(() {
      _vzoom = next.toDouble();
      _vpanX = nx;
      _vpanY = ny;
    });
  }

  void _onPointerDown(PointerDownEvent e, Size displaySize) {
    // Middle-mouse = viewport pan start.  Other buttons fall through to
    // the inner GestureDetector (left = image drag).
    if (e.buttons & kMiddleMouseButton == 0) return;
    _vPanning = true;
    _vPanStartScreenX = e.localPosition.dx;
    _vPanStartScreenY = e.localPosition.dy;
    _vPanOrigX = _vpanX;
    _vPanOrigY = _vpanY;
  }

  void _onPointerMove(PointerMoveEvent e, Size displaySize) {
    if (!_vPanning) return;
    var nx = _vPanOrigX + (e.localPosition.dx - _vPanStartScreenX);
    var ny = _vPanOrigY + (e.localPosition.dy - _vPanStartScreenY);
    // Clamp so at least half the rendered image stays on screen
    // (RR_VHS_Tool.py:11364-11376).
    final dw = displaySize.width * _vzoom;
    final dh = displaySize.height * _vzoom;
    final maxPx = (dw / 2 > displaySize.width / 2)
        ? dw / 2
        : displaySize.width / 2;
    final maxPy = (dh / 2 > displaySize.height / 2)
        ? dh / 2
        : displaySize.height / 2;
    nx = nx.clamp(-maxPx, maxPx);
    ny = ny.clamp(-maxPy, maxPy);
    setState(() {
      _vpanX = nx;
      _vpanY = ny;
    });
  }

  void _onPointerUp(PointerUpEvent _) {
    if (!_vPanning) return;
    setState(() => _vPanning = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.file.existsSync()) {
      return Builder(builder: widget.onMissing);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // The viewport (zoom + pan) is applied OUTSIDE the cover-image
        // stack so the safe-area overlay zooms with the canvas — that's
        // what makes wheel-zoom feel like a magnifier on the canvas
        // itself.  The "?" help button stays outside the viewport so it
        // remains anchored to the cropper frame.
        return Stack(
          fit: StackFit.expand,
          // Clip.none lets the T_Layout cassette-body overlay paint past
          // the cover-box bounds (sq ≈ 2.5× the cover width).  The HUD
          // buttons stay positioned via `Positioned` and are bounded by
          // their own coords, so this doesn't free them to draw outside
          // the cropper either.
          clipBehavior: Clip.none,
          children: [
            Listener(
              onPointerSignal: (e) => _onScroll(e, size),
              onPointerDown: (e) => _onPointerDown(e, size),
              onPointerMove: (e) => _onPointerMove(e, size),
              onPointerUp: _onPointerUp,
              child: MouseRegion(
                cursor: _vPanning
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.move,
                child: GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: (d) => _onPanUpdate(d, size),
                  onPanEnd: _onPanEnd,
                  // Transform on the OUTSIDE so cover + safe-overlay +
                  // T_Layout overlay all share the same viewport zoom
                  // and middle-mouse pan.  The inner Stack uses
                  // `Clip.none` so the layout texture can paint past
                  // the cover-box clip; the cover image itself sits in
                  // its own `ClipRect` so left-mouse drag still clips.
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(_vpanX, _vpanY, 0, 1)
                      ..scaleByDouble(_vzoom, _vzoom, 1, 1),
                    child: Stack(
                      clipBehavior: Clip.none,
                      fit: StackFit.expand,
                      children: [
                        ClipRect(
                          child: buildCoverImageStack(
                            file: widget.file,
                            imageWidth: widget.imageWidth,
                            imageHeight: widget.imageHeight,
                            offsetX: _x,
                            offsetY: _y,
                            zoom: _zoom,
                            imageGeneration: widget.imageGeneration,
                            size: size,
                            // Cap cacheWidth at moderate zoom — avoids
                            // a huge decode at vz=4 while staying sharp
                            // through 2×.
                            cacheWidthMultiplier: 4.0,
                            overlay: IgnorePointer(
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Red hidden zones + cyan visible-area
                                  // outline — always drawn on genre slots,
                                  // never on NR slots (NRs use the full
                                  // canvas and have their own zone overlay
                                  // below).
                                  if (widget.nrShape == null)
                                    CustomPaint(
                                      size: size,
                                      painter: SafeAreaOverlayPainter(
                                        layout: widget.layout,
                                        centerSnapX: _centerSnapX,
                                        centerSnapY: _centerSnapY,
                                        showLayoutOverlay: widget.showOverlay,
                                      ),
                                    ),
                                  if (widget.nrShape != null)
                                    CustomPaint(
                                      size: size,
                                      painter: _NrZoneOverlayPainter(
                                        shape: widget.nrShape!,
                                        standeeMode: widget.standeeMode,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // T_Layout cassette-body texture — sibling of
                        // the ClipRect-wrapped cover so it can paint
                        // outside the cover bounds, but inside the
                        // viewport Transform so middle-mouse pan +
                        // wheel-zoom move it together with the cover.
                        if (widget.showOverlay &&
                            widget.layout >= 1 &&
                            widget.layout <= 5 &&
                            widget.nrShape == null)
                          Positioned.fill(
                            child: Consumer(
                              builder: (context, ref, _) {
                                final imgAsync = ref.watch(
                                    layoutOverlayImageProvider(
                                        widget.layout));
                                final image = imgAsync.asData?.value;
                                if (image == null) {
                                  return const SizedBox.shrink();
                                }
                                return IgnorePointer(
                                  child: CustomPaint(
                                    painter: LayoutOverlayPainter(
                                      image: image,
                                      layout: widget.layout,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(top: 6, right: 6, child: _CanvasHelpButton()),
            const Positioned(left: 6, bottom: 6, child: _ControlsHud()),
          ],
        );
      },
    );
  }
}

/// Paints two overlays on the cropper canvas, both anchored to the
/// 1024×2048 bg-texture coordinate system:
///
/// 1. Red diagonal-hatched bands over the four hidden zones (top, bottom,
///    left, right) — port of `_draw_hidden_overlays_on_image`
///    (RR_VHS_Tool.py:12471-12530).
/// 2. A cyan dashed border around the visible rectangle — port of
///    `_draw_safe_border_on_canvas` (RR_VHS_Tool.py:12532-12580).
///
/// When the slot's layout is 1..5 we use [layoutVisibleRect]; otherwise we
/// fall back to the layout-agnostic [kHiddenTop]/[kHiddenBottom]/
/// [kHiddenLeft]/[kHiddenRight] bands the Python tool uses pre-layout
/// (RR_VHS_Tool.py:11221-11225).
class SafeAreaOverlayPainter extends CustomPainter {
  final int layout;
  final bool centerSnapX;
  final bool centerSnapY;
  /// When true, the layout-texture overlay is being composited on top of
  /// this painter — suppress the cyan dashed border since the texture
  /// itself delineates the visible area (Python parity,
  /// RR_VHS_Tool.py:13200-13204).  Hatched zones still render.
  final bool showLayoutOverlay;
  const SafeAreaOverlayPainter({
    required this.layout,
    this.centerSnapX = false,
    this.centerSnapY = false,
    this.showLayoutOverlay = false,
  });

  // Match Python's hatch palette (RR_VHS_Tool.py:12462-12467, 12525).
  static const Color _hatchFill = Color(0x2D3B0000);   // (59,0,0,45)
  static const Color _hatchLine = Color(0x50C81E1E);   // (200,30,30,80)
  static const Color _hatchEdge = Color(0x78C81E1E);   // (200,30,30,120)

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final scale = size.width / kTextureBkgWidth;

    // Visible rect in bg-texture coords, with a per-layout fallback to the
    // global hidden-band constants when no valid layout is selected.
    final double visTop, visBot, visLeft, visRight;
    final r = layoutVisibleRect(layout);
    if (r != null) {
      visTop = r.top;
      visBot = r.bottom;
      visLeft = r.left;
      visRight = r.right;
    } else {
      visTop = kHiddenTop.toDouble();
      visBot = (kTextureBkgHeight - kHiddenBottom).toDouble();
      visLeft = kHiddenLeft.toDouble();
      visRight = (kTextureBkgWidth - kHiddenRight).toDouble();
    }

    final dvTop = (visTop * scale).clamp(0.0, size.height);
    final dvBot = (visBot * scale).clamp(0.0, size.height);
    final dvLeft = (visLeft * scale).clamp(0.0, size.width);
    final dvRight = (visRight * scale).clamp(0.0, size.width);

    final borderRect = Rect.fromLTRB(dvLeft, dvTop, dvRight, dvBot);

    // Red hatched hidden zones — always drawn, regardless of the
    // "Layout Overlay" toggle.  Python parity at RR_VHS_Tool.py:12614-
    // 12624: the hatch is composited on every genre-slot render, the
    // toggle only switches which *additional* layer (cyan line vs
    // T_Layout texture) shows on top.
    final zones = <Rect>[
      if (dvTop > 0) Rect.fromLTRB(0, 0, size.width, dvTop),
      if (dvBot < size.height)
        Rect.fromLTRB(0, dvBot, size.width, size.height),
      if (dvLeft > 0) Rect.fromLTRB(0, 0, dvLeft, size.height),
      if (dvRight < size.width)
        Rect.fromLTRB(dvRight, 0, size.width, size.height),
    ];
    for (final z in zones) {
      _paintHatchedZone(canvas, z);
    }

    // Cyan dashed visible-area border — suppressed when the T_Layout
    // texture overlay is composited on top (Python parity at
    // RR_VHS_Tool.py:13200-13204).  The texture itself delineates the
    // visible area, so the dashed border would only add clutter.
    if (!showLayoutOverlay && borderRect.width > 0 && borderRect.height > 0) {
      _paintDashedRect(canvas, borderRect);
    }

    // Centre-axis snap guides — only while the user is dragging and the
    // offset hits the safe-centre target.  Pythons `_show_snap_guides`
    // (RR_VHS_Tool.py:11450-11502) draws cyan dashed lines spanning the
    // safe area in the appropriate direction.
    if (centerSnapX && borderRect.width > 0) {
      final cx = (borderRect.left + borderRect.right) / 2;
      _paintDashedLine(
        canvas,
        Offset(cx, borderRect.top),
        Offset(cx, borderRect.bottom),
      );
    }
    if (centerSnapY && borderRect.height > 0) {
      final cy = (borderRect.top + borderRect.bottom) / 2;
      _paintDashedLine(
        canvas,
        Offset(borderRect.left, cy),
        Offset(borderRect.right, cy),
      );
    }
  }

  void _paintDashedLine(Canvas canvas, Offset a, Offset b) {
    final paint = Paint()
      ..color = kColorCyan
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 4.0;
    const gap = 3.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final length = (dx * dx + dy * dy).abs();
    if (length == 0) return;
    final ux = dx / (b - a).distance;
    final uy = dy / (b - a).distance;
    var t = 0.0;
    final total = (b - a).distance;
    while (t < total) {
      final t2 = (t + dash).clamp(0.0, total);
      canvas.drawLine(
        Offset(a.dx + ux * t, a.dy + uy * t),
        Offset(a.dx + ux * t2, a.dy + uy * t2),
        paint,
      );
      t += dash + gap;
    }
  }

  void _paintHatchedZone(Canvas canvas, Rect rect) {
    if (rect.width <= 0 || rect.height <= 0) return;

    canvas.save();
    canvas.clipRect(rect);

    // Base fill — matches the dark-red tile fill in Python's hatch tile.
    canvas.drawRect(rect, Paint()..color = _hatchFill);

    // Diagonal hatch lines, every 8 px (Python builds three diagonals per
    // 16×16 tile at offsets 0/-8/+8 → effectively a line every 8 px).
    final linePaint = Paint()
      ..color = _hatchLine
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const step = 8.0;
    final h = rect.height;
    // x ranges from rect.left - h (lines going off the left) up to
    // rect.right (last line ending at top-right corner).
    var x = rect.left - h;
    while (x <= rect.right) {
      canvas.drawLine(
        Offset(x, rect.top),
        Offset(x + h, rect.bottom),
        linePaint,
      );
      x += step;
    }

    canvas.restore();

    // Bright red 1-px outline around the zone.
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = _hatchEdge
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  void _paintDashedRect(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..color = kColorCyan
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 6.0;
    const gap = 3.0;

    // Horizontal edges (top + bottom).
    void hEdge(double y) {
      var x = rect.left;
      while (x < rect.right) {
        final end = (x + dash).clamp(rect.left, rect.right);
        canvas.drawLine(Offset(x, y), Offset(end, y), paint);
        x += dash + gap;
      }
    }

    // Vertical edges (left + right).
    void vEdge(double x) {
      var y = rect.top;
      while (y < rect.bottom) {
        final end = (y + dash).clamp(rect.top, rect.bottom);
        canvas.drawLine(Offset(x, y), Offset(x, end), paint);
        y += dash + gap;
      }
    }

    hEdge(rect.top);
    hEdge(rect.bottom);
    vEdge(rect.left);
    vEdge(rect.right);
  }

  @override
  bool shouldRepaint(SafeAreaOverlayPainter old) =>
      old.layout != layout ||
      old.centerSnapX != centerSnapX ||
      old.centerSnapY != centerSnapY ||
      old.showLayoutOverlay != showLayoutOverlay;
}

/// Composites the alpha-masked `T_Layout_NN_bc_full.png` cassette body
/// over the cropper canvas so the user sees the in-game VHS frame
/// wrapping their cover.  Pure port of RR_VHS_Tool.py:12805-12884.
///
/// Math (per Python lines 12822-12847):
/// ```
///   bg_top  = fit_top
///   bg_bot  = TEX_HEIGHT - fit_bottom_hidden
///   lscale  = (bg_bot - bg_top) / (window.bottom - window.top)
///   loy     = bg_top - window.top * lscale  +  nudge_y
///   if window_w > TEX_WIDTH: lox = (L4?0:HIDDEN_LEFT) - window.left * lscale
///   else:                    lox = TEX_WIDTH - window.right * lscale
///   lox += nudge_x
///   sq      = 2048 * lscale * (canvas.width / TEX_WIDTH)
///   (lx, ly) = (lox, loy) * canvas.width / TEX_WIDTH
/// ```
/// In our painter coordinate frame the cropper canvas is at `(0,0)` so
/// Python's `_real_dx/_real_dy` drop out.
///
/// Drawing order (Python lines 12860-12883):
///   1. Dark `#1a1a1a` fills in the four bands of the overlay square
///      that fall **outside** the bg canvas — these stop the transparent
///      window from showing whatever lies beyond the cover when the
///      texture extends past the canvas edge.
///   2. The alpha-masked texture itself, scaled `sq×sq` at `(lx, ly)`.
///
/// The [image] is the full 2048×2048 RGBA texture; Flutter resamples
/// at draw time so we cache exactly one `ui.Image` per layout regardless
/// of viewport zoom.
class LayoutOverlayPainter extends CustomPainter {
  final ui.Image image;
  final int layout;
  const LayoutOverlayPainter({required this.image, required this.layout});

  static const Color _darkFill = Color(0xFF1A1A1A);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final placement = layoutOverlayPlacement(layout);
    if (placement == null) return;

    final texToScreen = size.width / kTextureBkgWidth;
    final sq = placement.scaledSize * texToScreen;
    final lx = placement.lox * texToScreen;
    final ly = placement.loy * texToScreen;

    // Dark fills in the parts of the overlay square that fall outside
    // the cropper canvas — stops the transparent "window" from showing
    // whatever sits behind the cropper through those gaps.
    final fillPaint = Paint()..color = _darkFill;
    if (lx < 0) {
      canvas.drawRect(Rect.fromLTRB(lx, ly, 0, ly + sq), fillPaint);
    }
    if (lx + sq > size.width) {
      canvas.drawRect(
        Rect.fromLTRB(size.width, ly, lx + sq, ly + sq),
        fillPaint,
      );
    }
    if (ly < 0) {
      canvas.drawRect(
        Rect.fromLTRB(
          lx < 0 ? 0 : lx,
          ly,
          lx + sq > size.width ? size.width : lx + sq,
          0,
        ),
        fillPaint,
      );
    }
    if (ly + sq > size.height) {
      canvas.drawRect(
        Rect.fromLTRB(
          lx < 0 ? 0 : lx,
          size.height,
          lx + sq > size.width ? size.width : lx + sq,
          ly + sq,
        ),
        fillPaint,
      );
    }

    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Rect.fromLTWH(lx, ly, sq, sq);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(LayoutOverlayPainter old) =>
      !identical(old.image, image) || old.layout != layout;
}

/// Paints the NR standee zone overlay on top of the cover.
///
/// VHS mode (standeeMode=false): only the gold/brown zone lines —
/// title plate top, footer top, frame bottom, side plate margins.
///
/// Standee mode (standeeMode=true): zone lines PLUS shape-specific
/// overlay — semicircle arch for A, vertical fold lines for B,
/// quarter-circle corner arcs for C.
///
/// Pure port of the NR overlay drawing in RR_VHS_Tool.py:11943-12162.
/// Coordinate system: [size] is the cropper canvas in display pixels,
/// `kTextureBkgWidth × kTextureBkgHeight` (1024×2048) is the texture
/// space.  All zone values come from [kStandeeZones] in texture space
/// and are scaled to display via `size.width / kTextureBkgWidth`
/// (X axis) and `size.height / kTextureBkgHeight` (Y axis).
class _NrZoneOverlayPainter extends CustomPainter {
  final String shape;
  final bool standeeMode;
  const _NrZoneOverlayPainter({required this.shape, required this.standeeMode});

  // Python's gold/brown palette for zone lines (RR_VHS_Tool.py:11953-11960
  // and 12015-12084).
  static const Color _goldBright = Color(0xFFFFD84A);
  static const Color _goldDim = Color(0xFFAA8830);
  static const Color _brown = Color(0xFF665522);
  static const Color _shapeAccent = Color(0xFF6688AA);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final z = standeeZonesFor(shape);
    final sx = size.width / 1024;
    final sy = size.height / 2048;

    // ── Zone lines (drawn in both VHS and Standee modes) ───────────────
    // Gold dashed line at front_end (top of title plate).
    final tpY = z.frontEnd * sy;
    _dashedLine(canvas,
        Offset(0, tpY), Offset(size.width, tpY),
        color: _goldBright, strokeWidth: 2, dash: 8, gap: 4);

    // Dimmer gold dashed line at title_end (top of footer).
    final ftY = z.titleEnd * sy;
    _dashedLine(canvas,
        Offset(0, ftY), Offset(size.width, ftY),
        color: _goldDim, strokeWidth: 1, dash: 6, gap: 4);

    // Dark brown dashed line at footer_end (bottom frame cutoff).
    if (z.footerEnd < 2048) {
      final foY = z.footerEnd * sy;
      _dashedLine(canvas,
          Offset(0, foY), Offset(size.width, foY),
          color: _brown, strokeWidth: 1, dash: 4, gap: 4);
    }

    // Side plate margins.
    if (z.plateLeft > 0) {
      final x = z.plateLeft * sx;
      _dashedLine(canvas, Offset(x, tpY), Offset(x, size.height),
          color: _brown, strokeWidth: 1, dash: 3, gap: 3);
    }
    if (z.plateRight > 0) {
      final x = size.width - z.plateRight * sx;
      _dashedLine(canvas, Offset(x, tpY), Offset(x, size.height),
          color: _brown, strokeWidth: 1, dash: 3, gap: 3);
    }

    if (!standeeMode) return;

    // ── Shape-specific overlay (Standee mode only) ─────────────────────
    if (z.foldLeft > 0) {
      final x = z.foldLeft * sx;
      _dashedLine(canvas, Offset(x, 0), Offset(x, tpY),
          color: _shapeAccent, strokeWidth: 1, dash: 6, gap: 4);
    }
    if (z.foldRight > 0) {
      final x = size.width - z.foldRight * sx;
      _dashedLine(canvas, Offset(x, 0), Offset(x, tpY),
          color: _shapeAccent, strokeWidth: 1, dash: 6, gap: 4);
    }

    if (z.archCenterY > 0 && z.archRadius > 0) {
      // Standee A semicircle.  Centre at (texW/2, archCenterY); the arc
      // is the upper half of an ellipse since X and Y display scales
      // differ.
      final cy = z.archCenterY * sy;
      final cx = size.width / 2;
      final rDispX = z.archRadius * sx;
      final rDispY = z.archRadius * sy;
      _dashedArc(
        canvas,
        Rect.fromLTRB(cx - rDispX, cy - rDispY, cx + rDispX, cy + rDispY),
        startRad: 3.14159, // π — start at left
        sweepRad: 3.14159, // sweep upward through 180° back to right
        color: _shapeAccent,
        strokeWidth: 2,
        dash: 6,
        gap: 3,
      );
      // Vertical insets where the arch meets the rectangle.
      final inLeft = (1024 / 2 - z.archRadius) * sx;
      final inRight = (1024 / 2 + z.archRadius) * sx;
      _dashedLine(canvas, Offset(inLeft, 0), Offset(inLeft, cy),
          color: _shapeAccent, strokeWidth: 1, dash: 3, gap: 4);
      _dashedLine(canvas, Offset(inRight, 0), Offset(inRight, cy),
          color: _shapeAccent, strokeWidth: 1, dash: 3, gap: 4);
      // Shoulder lines from canvas edge to inset at y=cy.
      _dashedLine(canvas, Offset(0, cy), Offset(inLeft, cy),
          color: _shapeAccent, strokeWidth: 1, dash: 3, gap: 4);
      _dashedLine(canvas, Offset(inRight, cy), Offset(size.width, cy),
          color: _shapeAccent, strokeWidth: 1, dash: 3, gap: 4);
    }

    if (z.cornerRadius > 0) {
      // Standee C rounded corners.  Quarter arcs in each top corner.
      final rx = z.cornerRadius * sx;
      final ry = z.cornerRadius * sy;
      // Top-left arc — sweeps from 90° (left) to 180° (top).  In Flutter,
      // angle 0 = +X axis, π/2 = +Y axis (screen coords). drawArc with
      // startAngle=π and sweepAngle=π/2 sweeps from "leftward" up through
      // to "upward" — that's the inner curve of the corner.
      _dashedArc(canvas,
          Rect.fromLTRB(0, 0, 2 * rx, 2 * ry),
          startRad: 3.14159, // π
          sweepRad: 1.5708, // π/2
          color: _shapeAccent,
          strokeWidth: 1,
          dash: 4,
          gap: 3);
      // Top-right arc.  startAngle=3π/2 ("up"), sweep π/2 to "right".
      _dashedArc(canvas,
          Rect.fromLTRB(size.width - 2 * rx, 0, size.width, 2 * ry),
          startRad: 4.71239, // 3π/2
          sweepRad: 1.5708,
          color: _shapeAccent,
          strokeWidth: 1,
          dash: 4,
          gap: 3);
      // Short indicator strokes where the rounding starts.
      final p = Paint()
        ..color = _shapeAccent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(0, ry), Offset(rx / 3, ry), p);
      canvas.drawLine(Offset(rx, 0), Offset(rx, ry / 3), p);
      canvas.drawLine(
          Offset(size.width, ry), Offset(size.width - rx / 3, ry), p);
      canvas.drawLine(
          Offset(size.width - rx, 0), Offset(size.width - rx, ry / 3), p);
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b,
      {required Color color,
      required double strokeWidth,
      required double dash,
      required double gap}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final total = (b - a).distance;
    if (total == 0) return;
    final ux = (b.dx - a.dx) / total;
    final uy = (b.dy - a.dy) / total;
    var t = 0.0;
    while (t < total) {
      final t2 = (t + dash).clamp(0.0, total);
      canvas.drawLine(
        Offset(a.dx + ux * t, a.dy + uy * t),
        Offset(a.dx + ux * t2, a.dy + uy * t2),
        paint,
      );
      t += dash + gap;
    }
  }

  void _dashedArc(Canvas canvas, Rect rect,
      {required double startRad,
      required double sweepRad,
      required Color color,
      required double strokeWidth,
      required double dash,
      required double gap}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    // Approximate dashing by stepping through the arc in small angular
    // slices.  ~1° per step is enough for visually smooth dashes.
    const stepRad = 0.01745;
    final radius = (rect.width.abs() + rect.height.abs()) / 4;
    final dashRad = dash / radius;
    final gapRad = gap / radius;
    var a = startRad;
    final end = startRad + sweepRad;
    while (a < end) {
      final segEnd = (a + dashRad).clamp(startRad, end);
      canvas.drawArc(rect, a, segEnd - a, false, paint);
      a += dashRad + gapRad;
      // Suppress unused-warning for stepRad if compiler optimises out:
      if (stepRad < 0) break;
    }
  }

  @override
  bool shouldRepaint(_NrZoneOverlayPainter old) =>
      old.shape != shape || old.standeeMode != standeeMode;
}

/// Paints zone-name labels in the gutter LEFT of the NR cover (and a
/// matching "← fold" label in the right gutter for Standee B).  Pure port
/// of the `canvas.create_text` calls in `_render_preview_canvas`
/// (RR_VHS_Tool.py:12030-12084 + 12123-12126).
///
/// Layout assumption: the painter is rendered as a sibling of a centered
/// `AspectRatio(1024/2048)` cover inside a Stack/Positioned.fill, so its
/// `size` is the column's full width × the cover's height.  The cover
/// width is `size.height / 2` and is centred horizontally — labels are
/// positioned by recomputing those bounds, not by reading them out of the
/// child.
///
/// All Y values come from [kStandeeZones] in 1024×2048 texture space and
/// are scaled to display via `coverHeight / 2048`.  Label X is anchored
/// to `max(2, coverLeft - 6)` (right-aligned for left-gutter labels),
/// matching Pythons `_label_x = max(2, _real_dx - 6)` (Z. 12074).
///
/// Viewport zoom/pan inside the cropper is intentionally NOT applied:
/// labels stay anchored to the cropper FRAME, not the live viewport.
/// Wheel-zooming the cover will desync labels from their lines — accepted
/// trade-off for keeping the labels outside `Transform`/`ClipRect`.
class NrZoneLabelsPainter extends CustomPainter {
  final String shape;
  final bool standeeMode;
  const NrZoneLabelsPainter({required this.shape, required this.standeeMode});

  // Same palette as _NrZoneOverlayPainter so labels colour-match their lines.
  static const Color _goldBright = Color(0xFFFFD84A);
  static const Color _goldDim = Color(0xFFAA8830);
  static const Color _brown = Color(0xFF665522);
  static const Color _shapeAccent = Color(0xFF6688AA);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final z = standeeZonesFor(shape);

    // Cover bounds inside the painter's box.  AspectRatio 1024:2048 takes
    // the full available height and is centred horizontally.
    final coverHeight = size.height;
    final coverWidth = coverHeight / 2;
    final coverLeft = (size.width - coverWidth) / 2;
    final coverRight = coverLeft + coverWidth;
    if (coverWidth <= 0) return;

    final tpY = z.frontEnd * coverHeight / 2048;
    final ftY = z.titleEnd * coverHeight / 2048;
    final foY = z.footerEnd < 2048
        ? z.footerEnd * coverHeight / 2048
        : coverHeight;

    // Pythons `_label_x = max(2, _real_dx - 6)` — clamp so labels never
    // fall off the very left edge of the column when the gutter is small.
    final labelX = (coverLeft - 6).clamp(2.0, double.infinity);

    // ── Title plate ────────────────────────────────────────────────────
    final titleText = z.titleBelowFooter
        ? 'Title plate (shown below footer on standee)'
        : 'Title plate';
    _paintRightAligned(canvas, labelX, (tpY + ftY) / 2, titleText, _goldBright);

    // ── Footer / base ──────────────────────────────────────────────────
    _paintRightAligned(
        canvas, labelX, (ftY + foY) / 2, 'Footer / base', _goldDim);

    // ── Frame color ────────────────────────────────────────────────────
    if (z.footerEnd < 2048) {
      _paintRightAligned(
          canvas, labelX, (foY + coverHeight) / 2, 'Frame color', _brown);
    }

    if (!standeeMode) return;

    // ── Standee A: Arch label at archCenterY ───────────────────────────
    if (z.archCenterY > 0 && z.archRadius > 0) {
      final archY = z.archCenterY * coverHeight / 2048;
      _paintRightAligned(canvas, labelX, archY, 'Arch', _shapeAccent);
    }

    // ── Standee B: fold labels at top of both gutters ──────────────────
    if (z.foldLeft > 0 || z.foldRight > 0) {
      _paintRightAligned(canvas, labelX, 14, 'fold →', _shapeAccent);
      _paintLeftAligned(
          canvas, coverRight + 6, 14, '← fold', _shapeAccent);
    }
  }

  void _paintRightAligned(
      Canvas canvas, double xRight, double yMid, String text, Color color) {
    final tp = _layoutText(text, color);
    tp.paint(canvas, Offset(xRight - tp.width, yMid - tp.height / 2));
  }

  void _paintLeftAligned(
      Canvas canvas, double xLeft, double yMid, String text, Color color) {
    final tp = _layoutText(text, color);
    tp.paint(canvas, Offset(xLeft, yMid - tp.height / 2));
  }

  TextPainter _layoutText(String text, Color color) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: kFsMeta,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(NrZoneLabelsPainter old) =>
      old.shape != shape || old.standeeMode != standeeMode;
}

/// Bottom-left HUD overlay listing the cropper's mouse bindings + a
/// snap-to-guides toggle (RR_VHS_Tool.py:12327-12424).  Minimisable to a
/// single ⚙ icon to keep out of the way for users who already know the
/// controls.  HUD-minimised state is local — it doesn't persist across
/// app restarts (matches Python).
class _ControlsHud extends ConsumerStatefulWidget {
  const _ControlsHud();

  @override
  ConsumerState<_ControlsHud> createState() => _ControlsHudState();
}

class _ControlsHudState extends ConsumerState<_ControlsHud> {
  bool _minimized = false;

  // Pythons HUD palette — kept as locals so this stays self-contained.
  static const Color _hudBg = Color(0xFF0B1218);
  static const Color _hudBorder = Color(0xFF004D55);

  @override
  Widget build(BuildContext context) {
    final snapOn = ref.watch(snapEnabledProvider);

    if (_minimized) {
      return _HudIconButton(
        glyph: '⚙',
        onTap: () => setState(() => _minimized = false),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _hudBg,
        border: Border.all(color: _hudBorder),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'CONTROLS',
                style: TextStyle(
                  fontSize: kFsMeta,
                  fontWeight: FontWeight.w700,
                  color: kColorText3,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(width: kSp4),
              _HudMinButton(
                glyph: '−',
                onTap: () => setState(() => _minimized = true),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Divider(height: 1, color: kColorBorder),
          const SizedBox(height: 4),
          const _HudKeyRow(key_: 'Scroll', value: 'Zoom'),
          const _HudKeyRow(key_: 'Middle drag', value: 'Pan viewport'),
          const _HudKeyRow(key_: 'Left drag', value: 'Move image'),
          const SizedBox(height: 4),
          const Divider(height: 1, color: kColorBorder),
          const SizedBox(height: 4),
          _HudSnapToggle(
            on: snapOn,
            onTap: () =>
                ref.read(snapEnabledProvider.notifier).state = !snapOn,
          ),
        ],
      ),
    );
  }
}

class _HudKeyRow extends StatelessWidget {
  final String key_;
  final String value;
  const _HudKeyRow({required this.key_, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              key_,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: kFsMeta,
                fontWeight: FontWeight.w700,
                color: kColorText2,
              ),
            ),
          ),
          const SizedBox(width: kSp2),
          Text(
            value,
            style: const TextStyle(
              fontSize: kFsMeta,
              color: kColorText3,
            ),
          ),
        ],
      ),
    );
  }
}

class _HudSnapToggle extends StatefulWidget {
  final bool on;
  final VoidCallback onTap;
  const _HudSnapToggle({required this.on, required this.onTap});

  @override
  State<_HudSnapToggle> createState() => _HudSnapToggleState();
}

class _HudSnapToggleState extends State<_HudSnapToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final boxBorder = widget.on ? kColorCyan : kColorBorder;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: kColorSurface,
                border: Border.all(color: boxBorder),
              ),
              child: widget.on
                  ? const Icon(Icons.check, size: 9, color: kColorCyan)
                  : null,
            ),
            const SizedBox(width: 6),
            Text(
              'Snap to guides',
              style: TextStyle(
                fontSize: kFsMeta,
                color: widget.on
                    ? (_hover ? kColorText : kColorText2)
                    : kColorText3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HudIconButton extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;
  const _HudIconButton({required this.glyph, required this.onTap});

  @override
  State<_HudIconButton> createState() => _HudIconButtonState();
}

class _HudIconButtonState extends State<_HudIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kColorPanel.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(color: kColorBorder),
          ),
          child: Text(
            widget.glyph,
            style: TextStyle(
              fontSize: kFsMeta,
              fontWeight: FontWeight.w700,
              color: _hover ? kColorText : kColorText2,
            ),
          ),
        ),
      ),
    );
  }
}

class _HudMinButton extends StatefulWidget {
  final String glyph;
  final VoidCallback onTap;
  const _HudMinButton({required this.glyph, required this.onTap});

  @override
  State<_HudMinButton> createState() => _HudMinButtonState();
}

class _HudMinButtonState extends State<_HudMinButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            widget.glyph,
            style: TextStyle(
              fontSize: kFsBody,
              fontWeight: FontWeight.w700,
              color: _hover ? kColorText : kColorText3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small circular "?" button anchored to the cropper's top-right corner.
/// Click opens the canvas-guide dialog (RR_VHS_Tool.py:11685-11695,
/// 12318-12325).  Pythons ? button is drawn directly on the Tk canvas
/// alongside the HUD; in Flutter the cropper Stack is the natural home.
class _CanvasHelpButton extends StatefulWidget {
  @override
  State<_CanvasHelpButton> createState() => _CanvasHelpButtonState();
}

class _CanvasHelpButtonState extends State<_CanvasHelpButton> {
  bool _hover = false;

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Canvas Guide'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Red hatched areas — hidden in-game',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                'These regions are covered by the VHS tape model. '
                'Your artwork here will not be visible to players.',
              ),
              SizedBox(height: 12),
              Text(
                'Cyan dashed border — visible area',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                'Only content inside this border shows on the tape.',
              ),
              SizedBox(height: 12),
              Text(
                'Tip: use Fit Visible to fill the visible area.',
                style: TextStyle(color: kColorCyan),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = _hover ? kColorText : kColorText2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => _showHelp(context),
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kColorPanel.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(color: kColorBorder),
          ),
          child: Text(
            '?',
            style: TextStyle(
              fontSize: kFsMeta,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
