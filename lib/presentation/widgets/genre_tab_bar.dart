import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/custom_slot_naming.dart';
import '../providers/providers.dart';

/// Horizontal tab strip mirroring RR_VHS_Tool.py:7322-7432.
///
/// Tabs from left to right:
///   * `All Movies`
///   * one tab per genre (count badge = number of custom slots)
///   * `New Releases` (placeholder — slice 5 wires actual NR support)
///
/// The selected tab name lives in [selectedTabProvider]; clicking a tab
/// updates that provider and clears the slot selection (so the preview /
/// options column resets when you switch genres).
class GenreTabBar extends ConsumerWidget {
  const GenreTabBar({super.key});

  static const String _allMovies = 'All Movies';
  static const String _newReleases = 'New Releases';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedTabProvider);
    final counts = ref.watch(customSlotsProvider).maybeWhen(
          data: (m) => {for (final e in m.entries) e.key: e.value.length},
          orElse: () => const <String, int>{},
        );
    final nrCount = ref.watch(nrSlotsProvider).maybeWhen(
          data: (slots) => slots.length,
          orElse: () => 0,
        );

    final allCount = counts.values.fold<int>(0, (a, b) => a + b);

    final tabs = <_TabSpec>[
      _TabSpec(label: _allMovies, count: allCount),
      ...kGenres
          .where((g) => !kHiddenGenres.contains(g.name))
          .map((g) => _TabSpec(
                label: g.name,
                count: counts[g.dataTableName] ?? 0,
                color: kGenreColors[g.name],
              )),
      _TabSpec(label: _newReleases, count: nrCount),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: kColorBg,
        border: Border(
          top: BorderSide(color: kColorBorder),
          bottom: BorderSide(color: kColorBorder),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicHeight(
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++) ...[
                if (i == 1)
                  // 1px vertical divider between "All Movies" and the first
                  // genre tab — matches Python's separator at line 7393-7395.
                  const VerticalDivider(width: 1),
                _Tab(
                  spec: tabs[i],
                  selected: tabs[i].label == selected,
                  onTap: () {
                    ref.read(selectedTabProvider.notifier).state =
                        tabs[i].label;
                    ref.read(selectedSlotBkgProvider.notifier).state = null;
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final int count;

  /// Genre tint — present for the 12 visible genres, null for "All Movies"
  /// and "New Releases".  Drives both the selected-tab background colour
  /// and the unselected-tab bottom-stripe accent.
  final GenreColor? color;

  const _TabSpec({
    required this.label,
    required this.count,
    this.color,
  });
}

class _Tab extends StatelessWidget {
  final _TabSpec spec;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Resolve the four visual states — Python parity with
    // `_update_tab_colors` (RR_VHS_Tool.py:9636-9708):
    //
    //   * selected + genre colour      → genre bg, contrasting fg
    //   * selected + no genre colour   → panel bg, cyan accent (All Movies,
    //                                     New Releases)
    //   * unselected + genre colour    → app bg, 2px coloured bottom stripe
    //   * unselected + no genre colour → app bg, no stripe
    final gc = spec.color;
    final Color tabBg;
    final Color labelFg;
    final FontWeight labelWeight =
        selected ? FontWeight.w700 : FontWeight.w400;
    final Color bottomStripe;

    if (selected && gc != null) {
      tabBg = gc.bg;
      labelFg = gc.fg;
      bottomStripe = Colors.transparent;
    } else if (selected) {
      tabBg = kColorPanel;
      labelFg = kColorCyan;
      bottomStripe = kColorCyan;
    } else if (gc != null) {
      tabBg = kColorBg;
      labelFg = spec.count > 0 ? kColorText : kColorText3;
      bottomStripe = gc.bg;
    } else {
      tabBg = kColorBg;
      labelFg = spec.count > 0 ? kColorText : kColorText3;
      bottomStripe = Colors.transparent;
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        color: tabBg,
        padding: const EdgeInsets.symmetric(
            horizontal: kSp3, vertical: kSp2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: kFsBody,
                    fontWeight: labelWeight,
                    color: labelFg,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: kSp1),
                _CountBadge(
                  count: spec.count,
                  selected: selected,
                  genreColor: gc,
                ),
              ],
            ),
            const SizedBox(height: kSp1),
            Container(
              height: 2,
              width: 64,
              color: bottomStripe,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  final bool selected;
  final GenreColor? genreColor;

  const _CountBadge({
    required this.count,
    required this.selected,
    required this.genreColor,
  });

  @override
  Widget build(BuildContext context) {
    // Mirrors Python's badge palette (RR_VHS_Tool.py:9668-9678):
    //   * selected + genre colour     → invert: bg = fg of genre, fg = bg
    //   * selected + no genre colour  → cyan bg, dark fg
    //   * unselected                  → neutral border bg, dim fg
    final Color badgeBg;
    final Color badgeFg;
    if (selected && genreColor != null) {
      badgeBg = genreColor!.fg;
      badgeFg = genreColor!.bg;
    } else if (selected) {
      badgeBg = kColorCyan;
      badgeFg = kColorTextInv;
    } else {
      badgeBg = kColorBorder;
      badgeFg = kColorText3;
    }

    return Container(
      color: badgeBg,
      padding: const EdgeInsets.symmetric(horizontal: kSp1, vertical: 0),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: kFsMeta,
          color: badgeFg,
          height: 1.2,
        ),
      ),
    );
  }
}
