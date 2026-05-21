/// LN-8 (revised): static status pill — outlined chip with a coloured
/// dot + uppercase label, plus an optional soft halo.  The original
/// briefing wanted EDITED / ERROR pills to "breathe" (sin-wave opacity
/// loop), but at shelf scale that animation was either too subtle to
/// read or too busy when several pills sat next to each other.  The
/// pulse is gone; multiple glowing pills next to each other are fine
/// because the glow is static.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/bloom.dart';

/// Generic outlined pill — coloured dot + uppercase label + optional
/// soft halo.  Use [glow: true] for states that should draw attention
/// (EDITED, ERROR, SHIPPED-success).  Resting failure states
/// (UNSHIPPED) get the bordered chip without halo so they don't burn
/// bloom-budget at shelf scale.
///
/// [compact] tightens every internal dimension (padding, dot, font) so
/// the pill fits on a 145px-wide shelf card next to a star row without
/// blowing the horizontal budget.  Used by the slot-card body — most
/// other call sites should keep the default sizing.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool glow;
  final bool compact;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.glow = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final double hPad = compact ? 4 : 7;
    final double vPad = compact ? 2 : 3;
    final double dot = compact ? 4 : 5;
    final double gap = compact ? 4 : 5;
    final double font = compact ? 8 : 9;
    final double letterSp = compact ? 0.8 : 1.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        boxShadow: glow ? bloomSoft(color) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          SizedBox(width: gap),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: kFontFamily,
              color: color,
              fontSize: font,
              fontWeight: FontWeight.w700,
              letterSpacing: letterSp,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Drop-in replacement for the old `SlotStatusBadge`.  Maps the
/// `isEdited` / `isShipped` tracking flags to one of three rest states:
///
///   - !isShipped               → UNSHIPPED (dark-red, resting, no halo)
///   - isShipped && isEdited    → EDITED (amber, glow)
///   - isShipped && !isEdited   → no badge (clean rest state)
class SlotStatusPill extends StatelessWidget {
  final bool isEdited;
  final bool isShipped;
  final bool compact;

  const SlotStatusPill({
    super.key,
    required this.isEdited,
    required this.isShipped,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isShipped) {
      return StatusPill(
        label: 'Unshipped',
        color: kColorBadgeUnshipped,
        compact: compact,
      );
    }
    if (isEdited) {
      return StatusPill(
        label: 'Edited',
        color: kColorWarn,
        glow: true,
        compact: compact,
      );
    }
    return const SizedBox.shrink();
  }
}
