import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';

/// Full layout section under the cropper — port of Pythons `lay_outer`
/// frame (RR_VHS_Tool.py:8037-8182).  Three rows:
///
///   1. LAYOUT OVERLAY pill toggle + "Show on canvas" hint — drives
///      `layoutOverlayProvider`, controlling whether the safe-area
///      overlay is painted on the cropper canvas.
///   2. SAVED LAYOUT label + dice + 5 thumbnail cards (the existing
///      [LayoutStylePicker]).
///   3. "Layout is saved per movie" footer hint.
class LayoutSection extends ConsumerWidget {
  /// Currently saved layout style (1..5) for the slot.
  final int value;

  /// Called with the new layout style when the user clicks a card or
  /// rolls the dice.  Persists `slot.ls` upstream.
  final ValueChanged<int> onChanged;

  const LayoutSection({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overlayOn = ref.watch(layoutOverlayProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Row A — LAYOUT OVERLAY toggle.
        Row(
          children: [
            const Text(
              'LAYOUT OVERLAY',
              style: TextStyle(
                fontSize: kFsMeta,
                fontWeight: FontWeight.w700,
                color: kColorText3,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(width: kSp2),
            _OverlayPillToggle(
              on: overlayOn,
              onTap: () => ref.read(layoutOverlayProvider.notifier).state =
                  !overlayOn,
            ),
            const SizedBox(width: kSp2),
            const Text(
              'Show on canvas',
              style: TextStyle(fontSize: kFsMeta, color: kColorText3),
            ),
          ],
        ),
        const SizedBox(height: kSp1),
        LayoutStylePicker(value: value, onChanged: onChanged),
        const SizedBox(height: 2),
        const Text(
          'Layout is saved per movie',
          style: TextStyle(fontSize: kFsMeta, color: kColorText3),
        ),
      ],
    );
  }
}

/// Pill-style toggle matching Pythons `_overlay_toggle_canvas`
/// (RR_VHS_Tool.py:8073-8087).  34×16 with a 14×14 thumb that slides
/// between left=2 (off) and left=18 (on).  Track and thumb both gray —
/// no cyan accent — to fit the tool's terminal palette.  Click anywhere
/// on the pill toggles.
class _OverlayPillToggle extends StatefulWidget {
  final bool on;
  final VoidCallback onTap;
  const _OverlayPillToggle({required this.on, required this.onTap});

  @override
  State<_OverlayPillToggle> createState() => _OverlayPillToggleState();
}

class _OverlayPillToggleState extends State<_OverlayPillToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const w = 34.0;
    const h = 16.0;
    const thumbSize = 14.0;
    final trackColor = widget.on ? kColorText3 : kColorBorder;
    final thumbColor = widget.on
        ? (_hover ? kColorText : const Color(0xFFE6EAEC))
        : kColorText3;
    final thumbLeft = widget.on ? w - thumbSize - 1 : 1.0;

    return Tooltip(
      message: widget.on ? 'Hide layout overlay' : 'Show layout overlay',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: [
                // Track — Pythons rect spans 0,2 → W,H-2 leaving a 2-px
                // gap top/bottom, but our SizedBox is exactly h tall so
                // we use a Positioned to mirror the inset.
                Positioned(
                  left: 0,
                  top: 2,
                  right: 0,
                  bottom: 2,
                  child: Container(color: trackColor),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  left: thumbLeft,
                  top: 1,
                  width: thumbSize,
                  height: thumbSize,
                  child: Container(color: thumbColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row of 5 layout-style thumbnail cards + dice (random) button, mirroring
/// the Python tool's "SAVED LAYOUT" panel (RR_VHS_Tool.py:8094-8182).
///
/// Each card shows a real game-frame thumbnail when the user has the
/// extracted PNG at `<workingDir>/layout_cache/T_Layout_NN_bc_full.png`
/// (the Python tool generates these on first run from the base-game pak).
/// When the file is missing, the card falls back to a numbered placeholder
/// so the picker is still usable.
///
/// Active card has a cyan border. Click sets `slot.ls` via the provided
/// callback.  Dice picks a random 1..5 and briefly surfaces a cyan
/// "Randomly selected: N" label below the row.
class LayoutStylePicker extends ConsumerStatefulWidget {
  /// Currently selected layout style (1..5).
  final int value;

  /// Called with the new layout style on click.
  final ValueChanged<int> onChanged;

  const LayoutStylePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  ConsumerState<LayoutStylePicker> createState() => _LayoutStylePickerState();
}

class _LayoutStylePickerState extends ConsumerState<LayoutStylePicker> {
  static final _rand = Random();
  String? _randomLabel;
  Timer? _randomLabelTimer;

  @override
  void dispose() {
    _randomLabelTimer?.cancel();
    super.dispose();
  }

  void _onDice() {
    // Pick from {1..5} \ {current} so the dice always changes the layout.
    // Diverges from Pythons `_on_dice_click` (RR_VHS_Tool.py:8120-8126),
    // which calls `randint(1, 5)` and can roll the same layout that's
    // already saved — visually a no-op the user reads as a broken button.
    final current = widget.value.clamp(1, 5);
    final candidates = [for (var i = 1; i <= 5; i++) if (i != current) i];
    final n = candidates[_rand.nextInt(candidates.length)];
    widget.onChanged(n);
    _randomLabelTimer?.cancel();
    setState(() => _randomLabel = 'Randomly selected: $n');
    _randomLabelTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _randomLabel = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(workingDirProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SAVED LAYOUT',
          style: TextStyle(
            fontSize: kFsMeta,
            fontWeight: FontWeight.w700,
            color: kColorCyan,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: kSp1),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _DiceButton(onTap: _onDice),
            const SizedBox(width: kSp3),
            for (var i = 1; i <= 5; i++) ...[
              if (i > 1) const SizedBox(width: kSp2),
              _LayoutCard(
                value: i,
                active: i == widget.value,
                workingDir: dir,
                onTap: () => widget.onChanged(i),
              ),
            ],
          ],
        ),
        // Reserve a fixed-height row so the layout doesn't jump as the
        // notification fades in/out.
        SizedBox(
          height: kFsMeta + 6,
          child: _randomLabel == null
              ? null
              : Text(
                  _randomLabel!,
                  style: const TextStyle(
                    fontSize: kFsMeta,
                    color: kColorCyan,
                  ),
                ),
        ),
      ],
    );
  }
}

class _DiceButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DiceButton({required this.onTap});

  @override
  State<_DiceButton> createState() => _DiceButtonState();
}

class _DiceButtonState extends State<_DiceButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Random — pick a layout at random',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 36,
            height: 82,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? kColorSurface : kColorPanel,
              border: Border.all(color: kColorBorder),
            ),
            child: Text(
              '⚄',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: _hover ? kColorText : kColorText2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LayoutCard extends StatelessWidget {
  final int value;
  final bool active;
  final String workingDir;
  final VoidCallback onTap;

  const _LayoutCard({
    required this.value,
    required this.active,
    required this.workingDir,
    required this.onTap,
  });

  static const _cardW = 50.0;
  static const _cardH = 82.0;

  @override
  Widget build(BuildContext context) {
    final path = p.join(
      workingDir,
      'layout_cache',
      'T_Layout_${value.toString().padLeft(2, '0')}_bc_full.png',
    );
    final file = File(path);
    final hasThumb = file.existsSync();
    final borderColor = active ? kColorCyan : kColorBorder;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: _cardW,
              height: _cardH,
              decoration: BoxDecoration(
                color: kColorPanel,
                border: Border.all(color: borderColor, width: active ? 2 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasThumb
                  ? _CroppedLayoutThumb(file: file)
                  : _PlaceholderThumb(value: value),
            ),
            const SizedBox(height: 2),
            Text(
              '$value',
              style: TextStyle(
                fontSize: kFsMeta,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active ? kColorCyan : kColorText3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Show the top-left ~half of a 2048×2048 layout PNG by overlaying a
/// 100×100 render of the full image onto a 50×82 clip rect anchored at
/// the top-left. Matches Python's `img.crop((0,0,1024,1650))` then resize.
class _CroppedLayoutThumb extends StatelessWidget {
  final File file;

  const _CroppedLayoutThumb({required this.file});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: OverflowBox(
        maxWidth: 100,
        maxHeight: 100,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 100,
          height: 100,
          // Decode at 200px wide — small bitmap; cuts memory vs full 2048.
          child: Image.file(file, fit: BoxFit.fill, cacheWidth: 200),
        ),
      ),
    );
  }
}

class _PlaceholderThumb extends StatelessWidget {
  final int value;

  const _PlaceholderThumb({required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kColorBg,
      alignment: Alignment.center,
      child: Text(
        '$value',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: kColorText3,
        ),
      ),
    );
  }
}
