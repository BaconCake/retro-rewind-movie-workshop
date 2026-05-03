import 'package:flutter/material.dart';

import '../../core/constants/genres.dart';

class GenreSidebar extends StatelessWidget {
  final GenreInfo? selected;
  final ValueChanged<GenreInfo> onSelect;

  const GenreSidebar({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListView.builder(
        itemCount: kGenres.length,
        itemBuilder: (context, i) {
          final g = kGenres[i];
          final isSel = selected?.code == g.code;
          return ListTile(
            dense: true,
            selected: isSel,
            title: Text(g.name),
            subtitle: Text('${g.bkgCount} slots',
                style: Theme.of(context).textTheme.bodySmall),
            onTap: () => onSelect(g),
          );
        },
      ),
    );
  }
}
