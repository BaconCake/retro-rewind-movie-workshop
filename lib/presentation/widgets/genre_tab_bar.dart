import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/bloom.dart';
import '../../domain/custom_slot_naming.dart';
import '../providers/providers.dart';

/// Horizontal tab strip — one tab per visible genre, plus "All Movies"
/// and "New Releases" pseudo-tabs at either end.  Mirrors Python's
/// RR_VHS_Tool.py:7322-7432 in structure, but the visuals were
/// reworked in LN-5 to drop the legacy filled-tab look in favour of
/// a glowing per-genre underline (matches the "Late Night Rental"
/// design language — only the active tab carries colour).
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
      _TabSpec(label: _allMovies, count: allCount, accent: kColorCyan),
      ...kGenres
          .where((g) => !kHiddenGenres.contains(g.name))
          .map((g) => _TabSpec(
                label: g.name,
                count: counts[g.dataTableName] ?? 0,
                // LN-5: per-genre accent drives both the active
                // underline and the active count-badge border.
                // Fallback to cyan keeps any not-yet-mapped genre
                // looking like a brand item rather than greyed out.
                accent: kGenreAccent[g.name] ?? kColorCyan,
              )),
      _TabSpec(label: _newReleases, count: nrCount, accent: kColorCyan),
    ];

    return DecoratedBox(
      decoration: const BoxDecoration(
        // No fill — ambient wash shows through.  Borders stay so the
        // strip still reads as a distinct band between header and body.
        border: Border(
          top: BorderSide(color: kColorBorder),
          bottom: BorderSide(color: kColorBorder),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i == 1)
                // 1px vertical divider between "All Movies" and the first
                // genre tab — matches Python's separator at 7393-7395.
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
    );
  }
}

class _TabSpec {
  final String label;
  final int count;

  /// LN-5 single-colour tint that drives the active underline and the
  /// count-badge border + text colour when the tab is selected.  Always
  /// non-null — "All Movies" and "New Releases" fall back to
  /// [kColorCyan] (brand) since they aren't per-genre views.
  final Color accent;

  const _TabSpec({
    required this.label,
    required this.count,
    required this.accent,
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
    final accent = spec.accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        // LN-5 vertical padding: 12 top / 14 bottom gives the underline
        // room to sit + bloom downward without colliding with the
        // strip's bottom border.
        padding: const EdgeInsets.fromLTRB(kSp3, 12, kSp3, 14),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  spec.label,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsBody,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? kColorText : kColorText3,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                _CountBadge(
                  count: spec.count,
                  selected: selected,
                  accent: accent,
                ),
              ],
            ),
            if (selected)
              Positioned(
                left: 0,
                right: 0,
                bottom: -1,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: accent,
                    // Two-layer downward bloom — the second shadow's
                    // y-offset is what makes the glow trail under the
                    // strip's bottom border rather than wrapping the bar
                    // symmetrically (which would feel chunky here).
                    boxShadow: [
                      BoxShadow(color: accent, blurRadius: 8),
                      BoxShadow(
                        color: accent,
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bordered count badge — always transparent fill (LN-5 / V4 visual
/// rule: counters are metadata, not CTAs).  Active state takes the
/// genre accent on both border and text + a subtle text bloom so the
/// number itself glows alongside the underline.
class _CountBadge extends StatelessWidget {
  final int count;
  final bool selected;
  final Color accent;

  const _CountBadge({
    required this.count,
    required this.selected,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? accent : kColorDivider,
        ),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 9,
          color: selected ? accent : kColorText4,
          shadows: selected ? textBloomSubtle(accent) : null,
          height: 1.2,
        ),
      ),
    );
  }
}
