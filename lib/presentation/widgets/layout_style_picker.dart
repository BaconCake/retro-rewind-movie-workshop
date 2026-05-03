import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';

/// Row of 5 layout-style thumbnail cards, mirroring the Python tool's
/// "SAVED LAYOUT" panel under the cover preview (RR_VHS_Tool.py:8094-8182).
///
/// Each card shows a real game-frame thumbnail when the user has the
/// extracted PNG at `<workingDir>/layout_cache/T_Layout_NN_bc_full.png`
/// (the Python tool generates these on first run from the base-game pak).
/// When the file is missing, the card falls back to a numbered placeholder
/// so the picker is still usable.
///
/// Active card has a cyan border. Click sets `slot.ls` via the provided
/// callback. The "LAYOUT OVERLAY" pill toggle from Python is intentionally
/// omitted for now — it controls a render-time overlay we don't have yet.
class LayoutStylePicker extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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
            for (var i = 1; i <= 5; i++) ...[
              if (i > 1) const SizedBox(width: kSp2),
              _LayoutCard(
                value: i,
                active: i == value,
                workingDir: dir,
                onTap: () => onChanged(i),
              ),
            ],
          ],
        ),
      ],
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
