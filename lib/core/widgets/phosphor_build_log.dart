/// LN-9: CRT-phosphor terminal surface for the build log.
///
/// Warm near-black background (`#0A0805`), warm dark-amber border
/// (`#2A1F10`), per-line text colour driven by content category:
///
///   - amber (kColorWarn) + amber bloom — the default / informational
///   - lime  (kColorShipped) + lime bloom — successful sub-steps
///   - pink  (kColorPink) + pink bloom — failures
///   - warm-dim (#7A5A28), no bloom — continuation lines (tree-style)
///
/// Subtle scanline veil (intensity 0.04) over the whole surface.  When
/// [running] is true, a 1 Hz step-blinking `▍` cursor sits below the
/// last line so the user sees activity even when no fresh log line has
/// landed yet.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'atmosphere.dart';

// File-local phosphor palette — these colours don't have roles outside
// this widget, so they don't live in app_theme.dart.  If a second
// terminal-style surface ever wants the same look, promote them then.
const Color _kPhosphorBg = Color(0xFF0A0805);
const Color _kPhosphorBorder = Color(0xFF2A1F10);
const Color _kPhosphorDim = Color(0xFF7A5A28);

class PhosphorBuildLog extends StatefulWidget {
  final List<String> lines;

  /// When true, an inline blinking cursor is appended below the last
  /// log line — visual cue that the build pipeline is still chewing.
  final bool running;

  const PhosphorBuildLog({
    super.key,
    required this.lines,
    this.running = false,
  });

  @override
  State<PhosphorBuildLog> createState() => _PhosphorBuildLogState();
}

class _PhosphorBuildLogState extends State<PhosphorBuildLog> {
  final ScrollController _scroll = ScrollController();

  /// Follow-tail flag: when true, new log lines auto-scroll the view
  /// to the bottom.  Toggled off the first time the user scrolls away
  /// from the tail, and back on the moment they return to it — gives
  /// the user manual control without losing the live-stream feel.
  bool _stickToBottom = true;

  // Tolerance in pixels — being within this many px of the bottom
  // still counts as "at the tail".  Stops a sub-pixel scroll position
  // from breaking the stick-to-bottom contract.
  static const double _tailEpsilon = 16;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(PhosphorBuildLog old) {
    super.didUpdateWidget(old);
    // New lines arrived AND we're tailing — schedule a jump to the
    // bottom on the next frame so the freshly-built ListView has its
    // updated maxScrollExtent.
    if (widget.lines.length > old.lines.length && _stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atTail = pos.pixels >= pos.maxScrollExtent - _tailEpsilon;
    if (atTail != _stickToBottom) {
      // setState only to trigger rebuild if we ever expose this flag
      // visually (e.g. a "live tail" badge) — currently invisible, but
      // the state still needs to flip so the next didUpdateWidget
      // honours the user's manual scroll.
      setState(() => _stickToBottom = atTail);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            color: _kPhosphorBg,
            border: Border.all(color: _kPhosphorBorder),
          ),
          padding: const EdgeInsets.all(kSp3),
          child: ListView.builder(
            controller: _scroll,
            itemCount: widget.lines.length + (widget.running ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == widget.lines.length) {
                return const _BlinkingCursor();
              }
              return _LogLine(text: widget.lines[i]);
            },
          ),
        ),
        // Scanline veil sits OVER the text, IgnorePointer'd inside the
        // overlay so clicks (e.g. selecting log text via copy button)
        // still reach the ListView below.
        const Positioned.fill(
          child: ScanlineOverlay(intensity: 0.04, spacing: 3),
        ),
      ],
    );
  }
}

class _LogLine extends StatelessWidget {
  final String text;
  const _LogLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final cat = _categorize(text);
    return Text(
      text,
      style: TextStyle(
        fontFamily: kFontFamily,
        fontSize: kFsMeta,
        color: cat.color,
        height: 1.3,
        shadows: cat.glow
            ? [
                Shadow(
                  color: cat.color.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Line category — colour + whether the line emits a phosphor glow.
class _LineCategory {
  final Color color;
  final bool glow;
  const _LineCategory(this.color, this.glow);
}

/// Substring-driven categorizer.  Substring matching (not regex) so
/// we stay tolerant of upstream log shape changes; the cost is the
/// occasional false-positive if a slot title happens to contain "OK"
/// — acceptable trade.  Mirrors the old `_logLineColor` logic with
/// the new phosphor palette + glow defaults.
_LineCategory _categorize(String line) {
  final l = line.toUpperCase();
  if (l.contains('FAIL') || l.contains('ERROR') || l.contains('[E0')) {
    return const _LineCategory(kColorPink, true);
  }
  if (l.contains(' OK') ||
      l.contains('INJECT ') ||
      l.contains('PLACEHOLDER ') ||
      l.contains('SUCCEEDED') ||
      l.contains('INSTALLED')) {
    return const _LineCategory(kColorShipped, true);
  }
  // Tree-style continuation / indented detail line — render dim, no
  // glow.  Helps the eye distinguish "this is the OK summary" from
  // "this is the file path that the OK refers to".
  if (line.startsWith('  ') ||
      line.startsWith('└') ||
      line.startsWith('├') ||
      line.startsWith('│')) {
    return const _LineCategory(_kPhosphorDim, false);
  }
  return const _LineCategory(kColorWarn, true);
}

/// 1 Hz step-blinking terminal cursor (`▍`).  Shown only while a build
/// is running so the user has constant feedback even on long sub-steps
/// that emit no log line for several seconds.
class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        // Step (not fade) — terminal cursors are discrete on/off,
        // a smooth opacity tween reads as a glow rather than a cursor.
        final visible = _c.value < 0.5;
        return Text(
          visible ? '▍' : ' ',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: kFsMeta,
            color: kColorWarn,
            height: 1.3,
            shadows: visible
                ? [
                    Shadow(
                      color: kColorWarn.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}
