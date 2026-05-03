import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Half-star rating picker — port of RR_VHS_Tool.py:8316-8501.
///
/// One row, six cells: a "0 stars" outline-star at left, then 5 star
/// cells. Each star cell is split in two: the left half = "half star",
/// the right half = "full star". Hovering a cell previews its rating in
/// cyan; clicking commits in gold.
///
/// Valid ratings: 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.5, 4.0, 4.5, 5.0.
/// 3.0 is intentionally rejected and auto-snaps to 2.5 — matches Python's
/// `_x_to_val` snap (RR_VHS_Tool.py:8454-8460).
///
/// A "GOOD CRITIC" / "BAD CRITIC" badge sits below the row and previews
/// on hover (RR_VHS_Tool.py:8514-8543). Buckets exactly match
/// `LAST2_TO_CRITIC` / `sku_to_info` (RR_VHS_Tool.py:1869-1880):
///   * stars >= 4.0          → GOOD CRITIC
///   * 2.0 <= stars <= 3.5   → no badge
///   * stars <= 1.5          → BAD CRITIC
class StarRatingPicker extends StatefulWidget {
  /// Currently selected rating (multiple of 0.5 except 3.0).
  final double value;

  /// Called when the user clicks a star cell. Receives the rounded
  /// half-star value (3.0 → 2.5 already applied).
  final ValueChanged<double> onChanged;

  const StarRatingPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<StarRatingPicker> createState() => _StarRatingPickerState();
}

class _StarRatingPickerState extends State<StarRatingPicker> {
  double? _hover;

  // 6 cells: index 0 = zero star, indices 1..5 = the five stars.
  static const _cellCount = 6;

  double _xToValue(double x, double width) {
    final cellW = width / _cellCount;
    final cell = (x / cellW).floor().clamp(0, _cellCount - 1);
    if (cell == 0) return 0.0;
    final intoCell = x - cell * cellW;
    final raw = intoCell < cellW / 2 ? cell - 0.5 : cell.toDouble();
    return raw == 3.0 ? 2.5 : raw; // 3.0 is not a valid rating in this game
  }

  @override
  Widget build(BuildContext context) {
    final shown = _hover ?? widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 36,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return MouseRegion(
                onHover: (e) =>
                    setState(() => _hover = _xToValue(e.localPosition.dx, w)),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  onTapDown: (e) =>
                      widget.onChanged(_xToValue(e.localPosition.dx, w)),
                  child: CustomPaint(
                    painter: _StarRowPainter(
                      committed: widget.value,
                      hover: _hover,
                      cellCount: _cellCount,
                    ),
                    size: Size(w, 36),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: kSp1),
        _CriticBadge(stars: shown),
      ],
    );
  }
}

class _StarRowPainter extends CustomPainter {
  final double committed;
  final double? hover;
  final int cellCount;

  _StarRowPainter({
    required this.committed,
    required this.hover,
    required this.cellCount,
  });

  static const _gold = Color(0xFFF5A623);
  static const _empty = Color(0xFF444444);
  static const _preview = Color(0xFF66E0F0);

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / cellCount;
    final cy = size.height / 2;
    final radius = (cellW / 2 - 2).clamp(8.0, 16.0);

    // Cell 0: outline-only zero indicator.
    _drawStar(canvas, Offset(cellW / 2, cy), radius,
        leftFill: _empty, rightFill: _empty, outlineOnly: true);

    final shown = hover ?? committed;
    final base = hover != null ? _preview : _gold;

    for (var i = 1; i <= 5; i++) {
      final cx = cellW * (i + 0.5);
      Color leftFill, rightFill;
      if (shown >= i) {
        leftFill = base;
        rightFill = base;
      } else if (shown >= i - 0.5) {
        leftFill = base;
        rightFill = _empty;
      } else {
        leftFill = _empty;
        rightFill = _empty;
      }
      _drawStar(canvas, Offset(cx, cy), radius,
          leftFill: leftFill, rightFill: rightFill);
    }
  }

  void _drawStar(
    Canvas canvas,
    Offset c,
    double r, {
    required Color leftFill,
    required Color rightFill,
    bool outlineOnly = false,
  }) {
    final path = _starPath(c, r);
    if (outlineOnly) {
      canvas.drawPath(
        path,
        Paint()
          ..color = leftFill
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      return;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(c.dx - r, c.dy - r, c.dx, c.dy + r));
    canvas.drawPath(path, Paint()..color = leftFill);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(c.dx, c.dy - r, c.dx + r, c.dy + r));
    canvas.drawPath(path, Paint()..color = rightFill);
    canvas.restore();
  }

  Path _starPath(Offset c, double r) {
    final innerR = r * 0.40;
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? r : innerR;
      // -π/2 start so the top point faces up; π/5 step → 10 vertices.
      final theta = -math.pi / 2 + i * (math.pi / 5);
      final x = c.dx + radius * math.cos(theta);
      final y = c.dy + radius * math.sin(theta);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _StarRowPainter old) =>
      old.committed != committed || old.hover != hover;
}

class _CriticBadge extends StatelessWidget {
  final double stars;

  const _CriticBadge({required this.stars});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _critic(stars);
    if (label.isEmpty) {
      // Reserve the same vertical space so the layout doesn't jump on hover.
      return const SizedBox(height: 18);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: kFsMeta,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 1,
        ),
      ),
    );
  }

  /// Bucket from RR_VHS_Tool.py:1869-1880.  4.0★ and up = good, 1.5★ and
  /// under = bad, the middle band shows nothing.
  (String, Color) _critic(double stars) {
    if (stars >= 4.0) return ('GOOD CRITIC', const Color(0xFF40DD40));
    if (stars <= 1.5) return ('BAD CRITIC', const Color(0xFFFF3030));
    return ('', kColorText3);
  }
}
