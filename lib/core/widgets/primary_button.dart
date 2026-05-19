/// LN-7 primary action button — solid filled CTA that blooms only on
/// hover/press, never at idle.
///
/// Replaces ad-hoc `FilledButton` / `ElevatedButton` call sites for the
/// CTAs that carry real weight: Ship-to-Store, Continue, Delete confirm,
/// Add-movie commit.  Ghost / outlined / link buttons stay on Material's
/// themed widgets — the bloom budget rule keeps them quiet.
///
/// Variants:
///   - default      → cyan fill, cyan bloom
///   - .destructive → pink fill, pink bloom (Delete confirms)
///
/// Disabled state renders as a transparent outlined ghost at 0.35
/// opacity so the disabled CTA reads as "not available" rather than as
/// a still-clickable grey button.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/bloom.dart';

class PrimaryButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget? icon;
  final String label;

  /// Pink fill + pink bloom for destructive confirms (Delete movie,
  /// Clear all custom slots).  Use the `.destructive` constructor in
  /// new call sites — it makes the intent obvious at the call site.
  final bool destructive;

  /// Compact density for dialog footers etc.  Tightens padding while
  /// keeping the typography + corner sharpness identical to the
  /// regular-density variant.
  final bool compact;

  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.compact = false,
  }) : destructive = false;

  const PrimaryButton.destructive({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.compact = false,
  }) : destructive = true;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _hover = false;
  bool _pressed = false;

  EdgeInsetsGeometry get _padding => widget.compact
      ? const EdgeInsets.symmetric(horizontal: kSp3, vertical: kSp2)
      : const EdgeInsets.symmetric(horizontal: kSp4, vertical: kSp3);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;

    // Disabled: outlined ghost at 0.35 opacity.  Renders the exact
    // same layout as the enabled state (icon + label + same padding)
    // so the button doesn't shift when its state toggles — important
    // for the SHIP button whose label/icon swap on every build cycle.
    if (!enabled) {
      return Opacity(
        opacity: 0.35,
        child: IgnorePointer(
          child: Container(
            padding: _padding,
            decoration: const BoxDecoration(
              color: Colors.transparent,
              border: Border.fromBorderSide(
                BorderSide(color: kColorDivider),
              ),
            ),
            child: _ButtonLabel(
              icon: widget.icon,
              label: widget.label,
              foreground: kColorDisabled,
            ),
          ),
        ),
      );
    }

    final accent = widget.destructive ? kColorPink : kColorCyan;
    final bloomShadows =
        widget.destructive ? kBloomPink : kBloomCyan;
    final bloomActive = _hover || _pressed;

    // Pressed darken — HSL-based "brightness × 0.92" so the darken
    // ratio reads consistently across cyan and pink (a pure RGB scale
    // would skew towards black on warm hues).
    final Color fillColour;
    if (_pressed) {
      final hsl = HSLColor.fromColor(accent);
      fillColour = hsl
          .withLightness((hsl.lightness * 0.92).clamp(0.0, 1.0))
          .toColor();
    } else {
      fillColour = accent;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: kAnimBase,
          curve: kCurveStandard,
          padding: _padding,
          decoration: BoxDecoration(
            color: fillColour,
            boxShadow: bloomActive ? bloomShadows : null,
          ),
          child: _ButtonLabel(
            icon: widget.icon,
            label: widget.label,
            foreground: kColorTextInv,
          ),
        ),
      ),
    );
  }
}

/// Shared label rendering — icon + spacer + text — so the enabled and
/// disabled branches stay in lockstep visually.
class _ButtonLabel extends StatelessWidget {
  final Widget? icon;
  final String label;
  final Color foreground;
  const _ButtonLabel({
    required this.icon,
    required this.label,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          // IconTheme so callers can pass a plain Icon() without
          // specifying a colour — it inherits the button's foreground
          // automatically and tracks enabled vs disabled state.
          IconTheme.merge(
            data: IconThemeData(color: foreground),
            child: icon!,
          ),
          const SizedBox(width: kSp2),
        ],
        Text(
          label,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontWeight: FontWeight.w700,
            fontSize: kFsBody,
            color: foreground,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}
