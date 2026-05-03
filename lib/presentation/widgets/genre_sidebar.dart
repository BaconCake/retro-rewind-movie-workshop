import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';

/// Vertical genre list, terminal-style.
///
/// Per row:
///   * 4-px-wide left stripe — cyan when selected, pink when the genre has
///     custom slots, transparent otherwise.  Mirrors the Python "list row
///     custom: left-stripe pink" rule (RR_VHS_Tool.py:5860-5862).
///   * Genre name in primary text colour.
///   * Custom-slot count in muted/pink depending on whether the genre is
///     untouched or customised.
class GenreSidebar extends ConsumerWidget {
  final GenreInfo? selected;
  final ValueChanged<GenreInfo> onSelect;

  const GenreSidebar({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(customSlotsProvider).maybeWhen(
          data: (m) => {for (final e in m.entries) e.key: e.value.length},
          orElse: () => const <String, int>{},
        );

    return Container(
      width: 220,
      color: kColorPanel,
      child: ListView.builder(
        itemCount: kGenres.length,
        itemBuilder: (context, i) {
          final g = kGenres[i];
          final isSel = selected?.code == g.code;
          final count = counts[g.dataTableName];
          return _GenreRow(
            genre: g,
            selected: isSel,
            count: count,
            onTap: () => onSelect(g),
          );
        },
      ),
    );
  }
}

class _GenreRow extends StatelessWidget {
  final GenreInfo genre;
  final bool selected;
  final int? count;
  final VoidCallback onTap;

  const _GenreRow({
    required this.genre,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasCustom = (count ?? 0) > 0;
    final stripeColor = selected
        ? kColorCyan
        : hasCustom
            ? kColorPink
            : Colors.transparent;
    final bg = selected ? kColorSurface : kColorPanel;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: bg,
        padding: EdgeInsets.zero,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: stripeColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSp3, kSp2, kSp3, kSp2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      genre.name,
                      style: TextStyle(
                        fontSize: kFsBody,
                        fontWeight: FontWeight.w700,
                        color: selected ? kColorCyan : kColorText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(count),
                      style: TextStyle(
                        fontSize: kFsMeta,
                        color: hasCustom ? kColorPink : kColorText3,
                      ),
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

  String _subtitle(int? c) {
    if (c == null) return '— custom slots';
    if (c == 0) return 'no custom slots';
    return '$c custom slot${c == 1 ? '' : 's'}';
  }
}
