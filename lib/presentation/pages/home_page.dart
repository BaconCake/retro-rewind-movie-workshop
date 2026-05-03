import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../providers/providers.dart';
import '../widgets/build_panel.dart';
import '../widgets/genre_sidebar.dart';
import '../widgets/texture_grid.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  GenreInfo _selected = kGenres.first;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RR Movie Workshop'),
        actions: [
          IconButton(
            tooltip: 'Reload custom_slots.json + replacements.json',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(customSlotsProvider);
              ref.invalidate(replacementsProvider);
            },
          ),
        ],
      ),
      body: Row(
        children: [
          GenreSidebar(
            selected: _selected,
            onSelect: (g) => setState(() => _selected = g),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: TextureGrid(genre: _selected)),
          const VerticalDivider(width: 1),
          const BuildPanel(),
        ],
      ),
    );
  }
}
