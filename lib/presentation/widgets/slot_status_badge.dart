import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// One-character render of the build-status three-state model
/// (RR_VHS_Tool.py:11443-11458).  Priority:
///
///   * `!isShipped` → **UNSHIPPED** (dark red) — slot has never made it
///     into a successful build.  Highest priority — once unshipped, the
///     edit state is irrelevant because everything is unshipped.
///   * `isShipped && isEdited` → **EDITED** (amber) — slot was shipped
///     once, then changed; the user has a pending edit to ship.
///   * `isShipped && !isEdited` → no badge (clean, in-sync state).
///
/// Surfaces as a bold uppercase text label sitting wherever the caller
/// places this widget.  Mirrors Python's plain canvas-text style — no
/// background pill, no border, no icon.
class SlotStatusBadge extends StatelessWidget {
  final bool isEdited;
  final bool isShipped;

  /// Optional font-size override.  Default matches Python's `FS["meta"]`
  /// which is [kFsMeta] in the Flutter port.
  final double fontSize;

  const SlotStatusBadge({
    super.key,
    required this.isEdited,
    required this.isShipped,
    this.fontSize = kFsMeta,
  });

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;
    if (!isShipped) {
      label = 'UNSHIPPED';
      color = kColorBadgeUnshipped;
    } else if (isEdited) {
      label = 'EDITED';
      color = kColorBadgeEdited;
    } else {
      return const SizedBox.shrink();
    }
    return Text(
      label,
      style: TextStyle(
        fontFamily: kFontFamily,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 1,
      ),
    );
  }
}
