import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/sku.dart';

/// Rarity selector — port of RR_VHS_Tool.py:8554-8700.
///
/// Two custom canvas buttons side by side: COMMON (cyan when active) and
/// ✦ LIMITED (deep-purple bg with rainbow segmented border when active).
/// Below them, an "Old tape" checkbox that flips Common ↔ Common (Old).
/// When LIMITED is selected, Old is force-locked ON and disabled
/// (RR_VHS_Tool.py:8682-8688) and a "Included with Limited." note appears
/// underneath.
class RarityPicker extends StatelessWidget {
  /// Currently active rarity. The picker maps it to:
  ///   * `Common`     → COMMON button + Old unchecked
  ///   * `Common (Old)` → COMMON button + Old checked
  ///   * `Limited Edition (holo)` → LIMITED button + Old locked-on
  /// `Random` is not surfaced here (it's only in the modal dialogs in
  /// Python — RR_VHS_Tool.py:12750+).
  final Rarity value;

  /// Called when the user picks a new rarity.
  final ValueChanged<Rarity> onChanged;

  const RarityPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  bool get _isLimited => value == Rarity.limited;
  bool get _isOld =>
      value == Rarity.commonOld || value == Rarity.limited;

  void _setLimited(bool v) {
    if (v) {
      onChanged(Rarity.limited);
    } else {
      // Switching off Limited: keep Old state from before, defaulting to
      // off (Python's _set_rar leaves the Old var alone, so re-enable
      // means whatever the checkbox was — we mirror by going to Common).
      onChanged(Rarity.common);
    }
  }

  void _setOld(bool v) {
    if (_isLimited) return; // Limited locks Old ON.
    onChanged(v ? Rarity.commonOld : Rarity.common);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RarityButton(
              label: 'Common',
              active: !_isLimited,
              variant: _RarityButtonVariant.common,
              onTap: () => _setLimited(false),
            ),
            const SizedBox(width: kSp1),
            _RarityButton(
              label: '✦  Limited',
              active: _isLimited,
              variant: _RarityButtonVariant.limited,
              onTap: () => _setLimited(true),
            ),
          ],
        ),
        const SizedBox(height: kSp2),
        Row(
          children: [
            // Reuse Material checkbox; tightened density to fit the panel.
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _isOld,
                onChanged: _isLimited ? null : (v) => _setOld(v ?? false),
                activeColor: kColorCyan,
                checkColor: kColorTextInv,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: kSp2),
            Text(
              'Old tape',
              style: TextStyle(
                fontSize: kFsBody,
                color: _isLimited ? kColorText3 : kColorText2,
              ),
            ),
          ],
        ),
        if (_isLimited)
          const Padding(
            padding: EdgeInsets.only(top: 2, left: 26),
            child: Text(
              'Included with Limited.',
              style: TextStyle(fontSize: kFsMeta, color: kColorText3),
            ),
          ),
      ],
    );
  }
}

enum _RarityButtonVariant { common, limited }

class _RarityButton extends StatelessWidget {
  final String label;
  final bool active;
  final _RarityButtonVariant variant;
  final VoidCallback onTap;

  const _RarityButton({
    required this.label,
    required this.active,
    required this.variant,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 34,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: CustomPaint(
            painter: _RarityButtonPainter(active: active, variant: variant),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: kFsBody,
                  fontWeight: variant == _RarityButtonVariant.limited
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: _textColor(),
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _textColor() {
    if (variant == _RarityButtonVariant.common) {
      return active ? kColorTextInv : kColorText3;
    }
    // Limited
    return active ? const Color(0xFFE0C0FF) : kColorText3;
  }
}

class _RarityButtonPainter extends CustomPainter {
  final bool active;
  final _RarityButtonVariant variant;

  _RarityButtonPainter({required this.active, required this.variant});

  // RR_VHS_Tool.py:8618 — fixed segmented rainbow palette.
  static const List<Color> _rainbow = [
    Color(0xFFFF3030),
    Color(0xFFFF8000),
    Color(0xFFFFD700),
    Color(0xFF40DD40),
    Color(0xFF2090FF),
    Color(0xFF9040FF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Rect.fromLTWH(0, 0, w, h);

    if (variant == _RarityButtonVariant.common) {
      final bg = active ? kColorCyan : kColorSurface;
      final border = active ? kColorCyan : kColorBorder;
      canvas.drawRect(rect, Paint()..color = bg);
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      return;
    }

    // Limited
    if (active) {
      canvas.drawRect(rect, Paint()..color = const Color(0xFF140820));
      _paintRainbowBorder(canvas, w, h);
    } else {
      canvas.drawRect(rect, Paint()..color = kColorSurface);
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()
          ..color = kColorBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _paintRainbowBorder(Canvas canvas, double w, double h) {
    const rim = 2.0;
    final segW = w / _rainbow.length;
    final segH = h / _rainbow.length;
    final paint = Paint()..strokeWidth = rim;

    for (var i = 0; i < _rainbow.length; i++) {
      paint.color = _rainbow[i];
      final x0 = i * segW;
      final x1 = (i + 1) * segW;
      canvas.drawLine(Offset(x0, 0), Offset(x1, 0), paint);
      canvas.drawLine(Offset(x0, h - 1), Offset(x1, h - 1), paint);
      final y0 = i * segH;
      final y1 = (i + 1) * segH;
      canvas.drawLine(Offset(0, y0), Offset(0, y1), paint);
      canvas.drawLine(Offset(w - 1, y0), Offset(w - 1, y1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RarityButtonPainter old) =>
      old.active != active || old.variant != variant;
}
