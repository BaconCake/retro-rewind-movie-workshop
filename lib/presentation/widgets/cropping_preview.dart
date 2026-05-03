import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';

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

  /// Live update during drag/scroll (every frame).
  final void Function(int offsetX, int offsetY, double zoom)? onPreview;

  /// Persistent commit at gesture end. Called with the final values when
  /// the user releases the mouse / stops scrolling for one tick.
  final void Function(int offsetX, int offsetY, double zoom) onCommit;

  /// Called when the file does not exist at build time.
  final WidgetBuilder onMissing;

  const CroppingPreview({
    super.key,
    required this.file,
    required this.savedOffsetX,
    required this.savedOffsetY,
    required this.savedZoom,
    required this.onCommit,
    required this.onMissing,
    this.onPreview,
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

  // Drag accounting in texture-pixel space (we accumulate fractional
  // remainders so small mouse moves don't get lost to integer rounding).
  double _dragAccumX = 0;
  double _dragAccumY = 0;

  @override
  void didUpdateWidget(covariant CroppingPreview old) {
    super.didUpdateWidget(old);
    // If saved values change while we're not dragging, drop any stale live
    // overrides so the preview reflects what's on disk.
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
    setState(() {
      _liveX = widget.savedOffsetX;
      _liveY = widget.savedOffsetY;
      _liveZoom = widget.savedZoom;
    });
  }

  void _onPanUpdate(DragUpdateDetails d, Size displaySize) {
    // Drag deltas come in display-pixel space. Convert to texture-pixel
    // space by dividing by the display→texture ratio.
    final scale = displaySize.width / kTextureBkgWidth;
    _dragAccumX += d.delta.dx / scale;
    _dragAccumY += d.delta.dy / scale;
    final newX = widget.savedOffsetX + _dragAccumX.round();
    final newY = widget.savedOffsetY + _dragAccumY.round();
    setState(() {
      _liveX = newX;
      _liveY = newY;
    });
    widget.onPreview?.call(newX, newY, _zoom);
  }

  void _onPanEnd(DragEndDetails _) {
    final x = _x, y = _y, z = _zoom;
    setState(() {
      _liveX = null;
      _liveY = null;
      _liveZoom = null;
    });
    widget.onCommit(x, y, z);
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // Wheel up (negative dy) → zoom in.
    final dir = e.scrollDelta.dy > 0 ? -1 : 1;
    final next = (_zoom + dir * 0.05).clamp(0.25, 4.0);
    if (next == _zoom) return;
    setState(() => _liveZoom = next);
    widget.onPreview?.call(_x, _y, next);
    // Persist immediately for scroll — no clean "release" event.
    widget.onCommit(_x, _y, next);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.file.existsSync()) {
      return Builder(builder: widget.onMissing);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = size.width / kTextureBkgWidth; // = h/2048
        final tx = _x * scale;
        final ty = _y * scale;
        return Listener(
          onPointerSignal: _onScroll,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: (d) => _onPanUpdate(d, size),
              onPanEnd: _onPanEnd,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: kColorBg),
                    Transform.translate(
                      offset: Offset(tx, ty),
                      child: Transform.scale(
                        scale: _zoom,
                        alignment: Alignment.center,
                        child: Image.file(
                          widget.file,
                          fit: BoxFit.cover,
                          // cap memory: 4× preview width is enough for sharp
                          // rendering even when zoomed in.
                          cacheWidth:
                              (size.width * 4).clamp(256, 4096).round(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
