import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
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
        title: const _Wordmark(),
        actions: [
          IconButton(
            tooltip: 'Reload custom_slots.json + replacements.json',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(customSlotsProvider);
              ref.invalidate(replacementsProvider);
            },
          ),
          const SizedBox(width: kSp2),
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

/// "📼 RETRO REWIND VHS" wordmark, mirroring Python's top-bar logo
/// (RR_VHS_Tool.py:7279-7286).  Pink "RETRO REWIND" + cyan "VHS" — the only
/// place in the app where two accent colours sit side by side.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(
      fontFamily: kFontFamily,
      fontFamilyFallback: kFontFamilyFallback,
      fontSize: kFsApp,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('📼', style: TextStyle(fontSize: 18)),
        const SizedBox(width: kSp2),
        Text('RETRO REWIND',
            style: titleStyle.copyWith(color: kColorPink)),
        const SizedBox(width: kSp1),
        Text('VHS', style: titleStyle.copyWith(color: kColorCyan)),
      ],
    );
  }
}
