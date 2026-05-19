/// LN-10 focus-bloom shell — wraps any focusable child (typically a
/// [TextField]) and emits a soft cyan halo while the descendant has
/// keyboard focus.
///
/// [InputDecoration] can colour the focused border via `focusedBorder`,
/// but its `BorderSide` API has no shadow slot — so the halo lives on
/// an [AnimatedContainer] one level up.  Alpha is tweened (not the
/// shadow list itself) so the appear/disappear is smooth instead of
/// snapping.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class FocusBloom extends StatefulWidget {
  final Widget child;

  /// Halo colour.  Defaults to cyan (input/focus = active CTA-ish).
  /// Pass [kColorPink] for fields inside destructive-confirm flows so
  /// the halo matches the field's pink focused border.
  final Color color;

  const FocusBloom({
    super.key,
    required this.child,
    this.color = kColorCyan,
  });

  @override
  State<FocusBloom> createState() => _FocusBloomState();
}

class _FocusBloomState extends State<FocusBloom> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // `canRequestFocus: false` + `skipTraversal: true` keeps focus on
      // the child TextField — this shell is just a listener.  Without
      // them, Tab traversal would land on the shell itself first.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: kAnimFast,
        curve: kCurveStandard,
        decoration: BoxDecoration(
          boxShadow: [
            // Render the shadow at every state but animate its alpha —
            // BoxDecoration.lerp animates each shadow's properties when
            // the list length stays constant, so going null↔list would
            // snap.  Keeping a constant single-shadow list yields a
            // smooth fade.
            BoxShadow(
              color: widget.color.withValues(alpha: _focused ? 0.45 : 0.0),
              blurRadius: 8,
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}
