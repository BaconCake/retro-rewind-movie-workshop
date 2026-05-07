import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';
import 'add_nr_slot_dialog.dart';
import 'add_slot_dialog.dart';
import 'cover_image.dart';

/// Shelf of custom slot cards for the active tab (left column of the
/// 3-column main layout — mirrors Python's "shelf" panel
/// RR_VHS_Tool.py:7434-7563).
///
/// The active tab lives in [selectedTabProvider]. Cards are clickable and
/// drive [selectedSlotBkgProvider] (cyan border = currently selected slot,
/// pink border = has user image, neutral border = empty placeholder).
class TextureGrid extends ConsumerWidget {
  const TextureGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(selectedTabProvider);
    final customSlots = ref.watch(customSlotsProvider);
    final replacements = ref.watch(replacementsProvider);

    if (tab == 'New Releases') {
      final nrAsync = ref.watch(nrSlotsProvider);
      return nrAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => _ErrorBanner(message: '$e'),
        data: (slots) => _NrSlotGrid(slots: slots),
      );
    }

    return customSlots.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _ErrorBanner(message: '$e'),
      data: (slotsByDt) => replacements.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => _ErrorBanner(message: '$e'),
        data: (replMap) => _SlotGrid(
          slots: _slotsForTab(tab, slotsByDt),
          replacements: replMap,
        ),
      ),
    );
  }

  /// "All Movies" → flatten every dataTable's slots in genre order.
  /// Genre tab → look up by `dataTableName` (note Kids → "Kid").
  List<SlotData> _slotsForTab(
    String tab,
    Map<String, List<SlotData>> slotsByDt,
  ) {
    if (tab == 'All Movies') {
      return [
        for (final g in kGenres) ...?slotsByDt[g.dataTableName],
      ];
    }
    final genre = kGenres.firstWhere(
      (g) => g.name == tab,
      orElse: () => kGenres.first,
    );
    return slotsByDt[genre.dataTableName] ?? const [];
  }
}

class _SlotGrid extends ConsumerWidget {
  final List<SlotData> slots;
  final Map<String, TextureReplacement> replacements;

  const _SlotGrid({required this.slots, required this.replacements});

  /// Pre-fill genre for the Add dialog. Null when on "All Movies"
  /// (the dialog falls back to its own picker).
  GenreInfo? _activeGenre(String tab) {
    if (tab == 'All Movies') return null;
    for (final g in kGenres) {
      if (g.name == tab) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(selectedTabProvider);
    final selectedBkg = ref.watch(selectedSlotBkgProvider);
    final activeGenre = _activeGenre(tab);

    // +1 cell for the "Add" tile (always shown unless we're on NR — that's
    // handled by the parent which short-circuits NR before instantiating
    // this widget).
    final itemCount = slots.length + 1;

    return GridView.builder(
      padding: const EdgeInsets.all(kSp3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.55,
        crossAxisSpacing: kSp3,
        mainAxisSpacing: kSp3,
      ),
      itemCount: itemCount,
      itemBuilder: (context, i) {
        if (i == slots.length) {
          return _AddSlotTile(
            initialGenre: activeGenre,
            onTap: () =>
                AddSlotDialog.show(context, initialGenre: activeGenre),
          );
        }
        final slot = slots[i];
        return _SlotCard(
          slot: slot,
          replacement: replacements[slot.bkgTex],
          selected: slot.bkgTex == selectedBkg,
          onTap: () =>
              ref.read(selectedSlotBkgProvider.notifier).state = slot.bkgTex,
        );
      },
    );
  }
}

/// "+ ADD MOVIE" tile, last cell of the shelf grid. Pink dashed border to
/// distinguish from real slots.
class _AddSlotTile extends StatelessWidget {
  final GenreInfo? initialGenre;
  final VoidCallback onTap;

  const _AddSlotTile({required this.initialGenre, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(color: kColorPink),
          child: Container(
            color: kColorPanel,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(kSp3),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add, color: kColorPink, size: 36),
                const SizedBox(height: kSp1),
                Text(
                  'ADD MOVIE',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: kFsMeta,
                    fontWeight: FontWeight.w700,
                    color: kColorPink,
                    letterSpacing: 1.5,
                  ),
                ),
                if (initialGenre != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'to ${initialGenre!.name}'.toUpperCase(),
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      color: kColorText3,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hand-rolled dashed-rectangle border painter — Flutter has no built-in.
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 6.0;
    const gap = 4.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    void hLine(double y) {
      var x = 0.0;
      while (x < size.width) {
        final x2 = (x + dash).clamp(0.0, size.width);
        canvas.drawLine(Offset(x, y), Offset(x2, y), paint);
        x += dash + gap;
      }
    }

    void vLine(double x) {
      var y = 0.0;
      while (y < size.height) {
        final y2 = (y + dash).clamp(0.0, size.height);
        canvas.drawLine(Offset(x, y), Offset(x, y2), paint);
        y += dash + gap;
      }
    }

    hLine(0);
    hLine(size.height - 1);
    vLine(0);
    vLine(size.width - 1);
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}

class _SlotCard extends StatelessWidget {
  final SlotData slot;
  final TextureReplacement? replacement;
  final bool selected;
  final VoidCallback onTap;

  const _SlotCard({
    required this.slot,
    required this.selected,
    required this.onTap,
    this.replacement,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = replacement != null;
    // Selection trumps customization: cyan when selected, pink when there's
    // a user image, neutral border for plain placeholders.
    final borderColor = selected
        ? kColorCyan
        : hasImage
            ? kColorPink
            : kColorBorder;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: kColorPanel,
          border: Border.all(
            color: borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _Thumbnail(
                replacement: replacement,
                layout: slot.ls,
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(kSp2, kSp1, kSp2, kSp2),
              decoration: const BoxDecoration(
                color: kColorPanel,
                border: Border(top: BorderSide(color: kColorBorder)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    slot.pnName.isEmpty ? '(untitled)' : slot.pnName,
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      fontWeight: FontWeight.w700,
                      color: kColorText,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    slot.bkgTex,
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      color: kColorText3,
                    ),
                  ),
                  if (slot.sku != 0)
                    Text(
                      'SKU ${slot.sku}',
                      style: const TextStyle(
                        fontSize: kFsMeta,
                        color: kColorText3,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends ConsumerWidget {
  final TextureReplacement? replacement;
  final int layout;

  const _Thumbnail({this.replacement, required this.layout});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = replacement;
    // Aspect of this slot's visible / cyan area — what the user actually
    // sees in-game.  Falls back to layout 1's rect for random/0 layouts
    // (we don't know which layout the game will pick at runtime).
    final visRect = layoutVisibleRectInt(layout < 1 || layout > 5 ? 1 : layout);
    final visAspect = visRect.width / visRect.height;

    Widget body;
    if (r == null) {
      body = const _Placeholder(
        label: 'NO IMAGE',
        sublabel: 'will render black in-game',
      );
    } else {
      final file = File(r.path);
      if (!file.existsSync()) {
        body = _Placeholder(
          label: 'IMAGE MISSING',
          sublabel: r.path,
          isError: true,
        );
      } else {
        body = _ThumbnailImage(
          file: file,
          replacement: r,
          viewport: visRect,
        );
      }
    }
    return Center(
      child: AspectRatio(aspectRatio: visAspect, child: body),
    );
  }
}

class _ThumbnailImage extends ConsumerWidget {
  final File file;
  final TextureReplacement replacement;
  final Rect viewport;

  const _ThumbnailImage({
    required this.file,
    required this.replacement,
    required this.viewport,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageGen = ref.watch(coverImageGenerationProvider(file.path));
    final dimsAsync = ref.watch(imageDimensionsProvider(file.path));
    return dimsAsync.when(
      loading: () => Container(color: kColorBg),
      error: (_, _) => const _Placeholder(
        label: 'DECODE ERROR',
        sublabel: '',
        isError: true,
      ),
      data: (dims) {
        if (dims == null) {
          return _Placeholder(
            label: 'IMAGE MISSING',
            sublabel: file.path,
            isError: true,
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            return buildCoverImageStack(
              file: file,
              imageWidth: dims.w,
              imageHeight: dims.h,
              offsetX: replacement.offsetX,
              offsetY: replacement.offsetY,
              zoom: replacement.zoom,
              imageGeneration: imageGen,
              size: Size(constraints.maxWidth, constraints.maxHeight),
              viewport: viewport,
              // Thumbnails can't be zoomed, so a small hi-DPI margin is
              // plenty.  Drops decode pixel count by ~7× vs. the cropper's
              // 4× headroom (4²/1.5² ≈ 7).
              cacheWidthMultiplier: 1.5,
            );
          },
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool isError;

  const _Placeholder({
    required this.label,
    required this.sublabel,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isError ? kColorPink : kColorText3;
    return Container(
      color: kColorBg,
      padding: const EdgeInsets.all(kSp2),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isError
                ? Icons.broken_image_outlined
                : Icons.image_not_supported_outlined,
            color: fg,
            size: 28,
          ),
          const SizedBox(height: kSp1),
          Text(
            label,
            style: TextStyle(
              fontSize: kFsMeta,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 1,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            sublabel,
            style: TextStyle(fontSize: kFsMeta, color: fg),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// NR shelf — sibling to [_SlotGrid] but driven by [nrSlotsProvider].
/// No image thumbnails (NR covers come from base-game `T_New_*` textures
/// at the moment; if we ever pre-decode them, this is the place to plug
/// them in).
class _NrSlotGrid extends ConsumerWidget {
  final List<NewReleaseSlot> slots;
  const _NrSlotGrid({required this.slots});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBkg = ref.watch(selectedSlotBkgProvider);

    return GridView.builder(
      padding: const EdgeInsets.all(kSp3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.55,
        crossAxisSpacing: kSp3,
        mainAxisSpacing: kSp3,
      ),
      itemCount: slots.length + 1,
      itemBuilder: (context, i) {
        if (i == slots.length) {
          return _AddNrTile(
            onTap: () => AddNrSlotDialog.show(context),
          );
        }
        final slot = slots[i];
        final selKey = '$kNrSelectionPrefix${slot.sku}';
        return _NrSlotCard(
          slot: slot,
          selected: selKey == selectedBkg,
          onTap: () =>
              ref.read(selectedSlotBkgProvider.notifier).state = selKey,
        );
      },
    );
  }
}

/// "+ ADD NEW RELEASE" tile — same dashed-pink-border treatment as the
/// genre-side [_AddSlotTile], visually consistent across both shelves.
class _AddNrTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddNrTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(color: kColorPink),
          child: Container(
            color: kColorPanel,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(kSp3),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add, color: kColorPink, size: 36),
                const SizedBox(height: kSp1),
                const Text(
                  'ADD NEW\nRELEASE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: kFsMeta,
                    fontWeight: FontWeight.w700,
                    color: kColorPink,
                    letterSpacing: 1.5,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NrSlotCard extends StatelessWidget {
  final NewReleaseSlot slot;
  final bool selected;
  final VoidCallback onTap;

  const _NrSlotCard({
    required this.slot,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? kColorCyan : kColorBorder;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: kColorPanel,
          border: Border.all(
            color: borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: kColorBg,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(kSp2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Genre code as the dominant visual — gives the user
                    // an instant read of which shelf this NR will land on.
                    Text(
                      slot.genreCode.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: kColorCyan,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: kSp1),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: kSp1, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: kColorPink, width: 1),
                      ),
                      child: Text(
                        'STANDEE ${slot.standeeShape}',
                        style: const TextStyle(
                          fontSize: kFsMeta,
                          fontWeight: FontWeight.w700,
                          color: kColorPink,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(kSp2, kSp1, kSp2, kSp2),
              decoration: const BoxDecoration(
                color: kColorPanel,
                border: Border(top: BorderSide(color: kColorBorder)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    slot.title.isEmpty ? '(untitled)' : slot.title,
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      fontWeight: FontWeight.w700,
                      color: kColorText,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    slot.bkgTex,
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      color: kColorText3,
                    ),
                  ),
                  Text(
                    'SKU ${slot.sku}',
                    style: const TextStyle(
                      fontSize: kFsMeta,
                      color: kColorText3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(kSp3),
      decoration: BoxDecoration(
        color: kColorPanel,
        border: Border.all(color: kColorPink),
      ),
      child: Text(
        'Could not load slot data: $message',
        style: const TextStyle(color: kColorPink, fontSize: kFsBody),
      ),
    );
  }
}
