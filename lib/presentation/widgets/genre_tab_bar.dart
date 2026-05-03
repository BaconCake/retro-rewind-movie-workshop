import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
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

    final allCount = counts.values.fold<int>(0, (a, b) => a + b);

    final tabs = <_TabSpec>[
      _TabSpec(label: _allMovies, count: allCount),
      ...kGenres.map((g) => _TabSpec(
            label: g.name,
            count: counts[g.dataTableName] ?? 0,
          )),
      const _TabSpec(label: _newReleases, count: 0),
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
  const _TabSpec({required this.label, required this.count});
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
    final hasCustom = spec.count > 0;
    final labelColor = selected
        ? kColorCyan
        : hasCustom
            ? kColorText
            : kColorText3;

    return InkWell(
      onTap: onTap,
      child: Padding(
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: labelColor,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: kSp1),
                _CountBadge(count: spec.count),
              ],
            ),
            const SizedBox(height: kSp1),
            // Underline — cyan 2px when selected, transparent otherwise.
            // Matches Python's tab underline (RR_VHS_Tool.py:7382).
            Container(
              height: 2,
              width: 64,
              color: selected ? kColorCyan : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kColorBorder,
      padding: const EdgeInsets.symmetric(horizontal: kSp1, vertical: 0),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: kFsMeta,
          color: kColorText3,
          height: 1.2,
        ),
      ),
    );
  }
}
