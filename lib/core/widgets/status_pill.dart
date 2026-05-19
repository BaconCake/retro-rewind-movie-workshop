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
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool glow;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        boxShadow: glow ? bloomSoft(color) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: kFontFamily,
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
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

  const SlotStatusPill({
    super.key,
    required this.isEdited,
    required this.isShipped,
  });

  @override
  Widget build(BuildContext context) {
    if (!isShipped) {
      return const StatusPill(
        label: 'Unshipped',
        color: kColorBadgeUnshipped,
      );
    }
    if (isEdited) {
      return const StatusPill(
        label: 'Edited',
        color: kColorWarn,
        glow: true,
      );
    }
    return const SizedBox.shrink();
  }
}
