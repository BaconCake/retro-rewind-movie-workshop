import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers/providers.dart';
import '../widgets/genre_tab_bar.dart';
import '../widgets/setup_dialog.dart';
import '../widgets/slot_options_panel.dart';
import '../widgets/slot_preview.dart';
import '../widgets/texture_grid.dart';

/// Top-level layout, mirroring RR_VHS_Tool.py's main window
/// (RR_VHS_Tool.py:7274-7570):
///
///   ┌──────────────────────────────────────────────┐
///   │ wordmark + actions                  (AppBar) │
///   ├──────────────────────────────────────────────┤
///   │ [All Movies] [Action] [Adult] … [New Releases]
///   ├────────────┬────────────────┬───────────────┤
///   │ shelf grid │ slot preview   │ options +     │
///   │ (cards)    │ (full cover)   │ build button  │
///   └────────────┴────────────────┴───────────────┘
///
/// The `shelf` width is fixed (≈ 4 cards wide) so the preview always has
/// breathing room. Options are pinned to a 360px right rail.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _setupChecked = false;

  /// Open the setup dialog if the loaded config doesn't point at real
  /// files/dirs — first-launch flow.  Runs once per HomePage mount; the
  /// re-entry button uses [_openSetup] directly.
  Future<void> _maybeShowSetupOnLaunch() async {
    if (_setupChecked) return;
    _setupChecked = true;
    final cfg = await ref.read(configFutureProvider.future);
    if (cfg.isReady) return;
    if (!mounted) return;
    await SetupDialog.show(context, ref);
  }

  Future<void> _openSetup() async {
    await SetupDialog.show(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    // Kick off the layout-texture preload as soon as the app paints, so
    // the work happens in the background while the user navigates instead
    // of being deferred until they open a slot.  We intentionally don't
    // surface its AsyncValue here — failures degrade silently to
    // placeholder thumbnails inside LayoutStylePicker.
    ref.watch(layoutPreloadProvider);
    // First frame: check config; if incomplete, pop the SetupDialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowSetupOnLaunch();
    });
    return Scaffold(
      appBar: AppBar(
        title: const _Wordmark(),
        actions: [
          IconButton(
            tooltip: 'Open setup dialog',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSetup,
          ),
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
      body: Column(
        children: const [
          GenreTabBar(),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 420, child: TextureGrid()),
                VerticalDivider(width: 1),
                Expanded(child: SlotPreview()),
                VerticalDivider(width: 1),
                SlotOptionsPanel(),
              ],
            ),
          ),
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
