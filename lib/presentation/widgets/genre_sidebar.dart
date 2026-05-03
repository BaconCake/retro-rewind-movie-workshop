import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../providers/providers.dart';

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
    // Custom-slot count per DataTable name. AsyncValue collapses to {} on
    // missing/loading so the sidebar stays usable even before the JSON is
    // resolved (count just shows "—" until then).
    final counts = ref.watch(customSlotsProvider).maybeWhen(
          data: (m) => {for (final e in m.entries) e.key: e.value.length},
          orElse: () => const <String, int>{},
        );

    return Container(
      width: 200,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView.builder(
        itemCount: kGenres.length,
        itemBuilder: (context, i) {
          final g = kGenres[i];
          final isSel = selected?.code == g.code;
          final count = counts[g.dataTableName];
          return ListTile(
            dense: true,
            selected: isSel,
            title: Text(g.name),
            subtitle: Text(
              count == null
                  ? '— custom slots'
                  : count == 0
                      ? 'no custom slots (base game shown)'
                      : '$count custom slot${count == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => onSelect(g),
          );
        },
      ),
    );
  }
}
