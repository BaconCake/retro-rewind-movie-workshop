import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/sort.dart';
import '../providers/providers.dart';
import 'add_nr_slot_dialog.dart';
import 'add_slot_dialog.dart';
import 'cover_image.dart';
import 'slot_status_badge.dart';
import 'sort_header_bar.dart';

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

    final tracking = ref.watch(trackingProvider);
    // Per-tab sort.  "All Movies" intentionally never sorts — briefing
    // §5.4 keeps the multi-genre overview in genre order so the user
    // can scan it as a single contiguous list.
    final sortKey = tab == 'All Movies'
        ? null
        : ref.watch(sortPrefsProvider.notifier).getForTab(tab);
    // Watching sortPrefsProvider itself triggers rebuild on selection
    // change.  getForTab reads from the latest state, so this watch is
    // what makes the grid resort when the user picks a new option.
    ref.watch(sortPrefsProvider);

    if (tab == 'New Releases') {
      final nrAsync = ref.watch(nrSlotsProvider);
      return Column(
        children: [
          SortHeaderBar(tabName: tab),
          Expanded(
            child: nrAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => _ErrorBanner(message: '$e'),
              data: (slots) => _NrSlotGrid(
                slots: sortKey == null ? slots : sortNrSlots(slots, sortKey),
                edited: tracking.edited,
                shipped: tracking.shipped,
              ),
            ),
          ),
        ],
      );
    }

    final gridContent = customSlots.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _ErrorBanner(message: '$e'),
      data: (slotsByDt) => replacements.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => _ErrorBanner(message: '$e'),
        data: (replMap) {
          final raw = _slotsForTab(tab, slotsByDt);
          final ordered = sortKey == null ? raw : sortSlots(raw, sortKey);
          return _SlotGrid(
            slots: ordered,
            replacements: replMap,
            edited: tracking.edited,
            shipped: tracking.shipped,
          );
        },
      ),
    );
    // No sort UI on "All Movies"; render the grid plainly.
    if (tab == 'All Movies') return gridContent;
    return Column(
      children: [
        SortHeaderBar(tabName: tab),
        Expanded(child: gridContent),
      ],
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
  final Set<String> edited;
  final Set<String> shipped;

  const _SlotGrid({
    required this.slots,
    required this.replacements,
    required this.edited,
    required this.shipped,
  });

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
        // RepaintBoundary keeps each card's paint layer separate, so
        // scrolling / selecting one card doesn't invalidate the others'
        // (decoded) raster.  Without this the GridView repaints all
        // visible cards on every selection / scroll tick — the source
        // of the stutter while thumbnails finish decoding.
        return RepaintBoundary(
          child: _SlotCard(
            slot: slot,
            replacement: replacements[slot.bkgTex],
            selected: slot.bkgTex == selectedBkg,
            isEdited: edited.contains(slot.bkgTex),
            isShipped: shipped.contains(slot.bkgTex),
            onTap: () => ref.read(selectedSlotBkgProvider.notifier).state =
                slot.bkgTex,
          ),
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
  final bool isEdited;
  final bool isShipped;
  final VoidCallback onTap;

  const _SlotCard({
    required this.slot,
    required this.selected,
    required this.onTap,
    required this.isEdited,
    required this.isShipped,
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _Thumbnail(
                      replacement: replacement,
                      layout: slot.ls,
                    ),
                  ),
                  // Status badge floats in the upper-right.  Wrapped in a
                  // tiny dark plate so the amber/red text stays readable
                  // over both bright covers and the dim placeholder bg.
                  if (isEdited || !isShipped)
                    Positioned(
                      top: kSp1,
                      right: kSp1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        color: kColorBg.withValues(alpha: 0.78),
                        child: SlotStatusBadge(
                          isEdited: isEdited,
                          isShipped: isShipped,
                        ),
                      ),
                    ),
                ],
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
      // `existsSync()` used to live here — one syscall per card per
      // rebuild was wasted work, since `_ThumbnailImage` already shows
      // the "IMAGE MISSING" placeholder when `imageDimensionsProvider`
      // resolves to null (which it does for missing files).
      body = _ThumbnailImage(
        file: File(r.path),
        replacement: r,
        viewport: visRect,
      );
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
              // Visible feedback while the cover is decoding — critical
              // on tab switches to a shelf full of fresh thumbnails.
              showDecodeProgress: true,
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
/// Renders as a FLAT vertical list of rows (genre-coloured 3-letter badge
/// + title), matching Python's NR shelf at RR_VHS_Tool.py:10642-10682.
/// The card-grid layout the genre shelf uses doesn't apply here — NR
/// covers come from base-game `T_New_*` textures that aren't pre-decoded
/// for shelf preview, so a row-list is both closer to Python and more
/// information-dense per pixel.
class _NrSlotGrid extends ConsumerWidget {
  final List<NewReleaseSlot> slots;
  final Set<String> edited;
  final Set<String> shipped;
  const _NrSlotGrid({
    required this.slots,
    required this.edited,
    required this.shipped,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBkg = ref.watch(selectedSlotBkgProvider);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: kSp2),
      itemCount: slots.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return _AddNrRow(onTap: () => AddNrSlotDialog.show(context));
        }
        final slot = slots[i - 1];
        final selKey = '$kNrSelectionPrefix${slot.sku}';
        final trackingKey = 'NR_${slot.sku}';
        return _NrSlotRow(
          slot: slot,
          selected: selKey == selectedBkg,
          isEdited: edited.contains(trackingKey),
          isShipped: shipped.contains(trackingKey),
          onTap: () =>
              ref.read(selectedSlotBkgProvider.notifier).state = selKey,
        );
      },
    );
  }
}

/// Add-NR row — single full-width strip with a dashed pink border + "+"
/// glyph, matching the visual language of the genre shelf's [_AddSlotTile]
/// but shaped to fit the NR row layout.  Sits at the top of the list so a
/// fresh NR creation lands above existing rows (no scroll needed).
class _AddNrRow extends StatelessWidget {
  final VoidCallback onTap;
  const _AddNrRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kSp2, 0, kSp2, kSp1),
          child: CustomPaint(
            painter: _DashedBorderPainter(color: kColorPink),
            child: Container(
              color: kColorPanel,
              padding: const EdgeInsets.symmetric(
                  horizontal: kSp2, vertical: kSp2),
              child: const Row(
                children: [
                  Icon(Icons.add, color: kColorPink, size: 18),
                  SizedBox(width: kSp2),
                  Text(
                    'ADD NEW RELEASE',
                    style: TextStyle(
                      fontSize: kFsMeta,
                      fontWeight: FontWeight.w700,
                      color: kColorPink,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One NR row in the shelf list.  Layout: [GENRE BADGE]  [Title text].
/// Genre badge uses [kGenreColors] (Python `GENRE_COLORS`); selected row
/// gets a 1px cyan border + cyan title + brighter background, matching
/// Python's selection treatment at RR_VHS_Tool.py:10650-10672.
class _NrSlotRow extends StatefulWidget {
  final NewReleaseSlot slot;
  final bool selected;
  final bool isEdited;
  final bool isShipped;
  final VoidCallback onTap;

  const _NrSlotRow({
    required this.slot,
    required this.selected,
    required this.isEdited,
    required this.isShipped,
    required this.onTap,
  });

  @override
  State<_NrSlotRow> createState() => _NrSlotRowState();
}

class _NrSlotRowState extends State<_NrSlotRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.slot;
    // Genre badge colours — fall back to neutral border/text3 when the
    // genre isn't in the colours map (matches Pythons `.get(..., {})`
    // fallback at RR_VHS_Tool.py:10659-10661).
    final gc = kGenreColors[s.genre];
    final badgeBg = gc?.bg ?? kColorBorder;
    final badgeFg = gc?.fg ?? kColorText3;

    final rowBg = widget.selected
        ? kColorPanel
        : (_hover ? kColorPanel : kColorSurface);
    final titleColor = widget.selected ? kColorCyan : kColorText;

    // Genre code: prefer the entitys 3-letter `genreCode`; fall back to
    // first-3-of-genre-name (Pythons `nr['genre'][:3].upper()`).
    final code = (s.genreCode.isNotEmpty
            ? s.genreCode
            : (s.genre.length >= 3 ? s.genre.substring(0, 3) : s.genre))
        .toUpperCase();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: kSp2, vertical: 1),
          decoration: BoxDecoration(
            color: rowBg,
            border: widget.selected
                ? Border.all(color: kColorCyan, width: 1)
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: kSp2, vertical: kSp1),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: kSp2, vertical: 2),
                color: badgeBg,
                child: Text(
                  code,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsMeta,
                    fontWeight: FontWeight.w700,
                    color: badgeFg,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(width: kSp2),
              Expanded(
                child: Text(
                  s.title.isEmpty ? '(untitled)' : s.title,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: kFsBody,
                    color: titleColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.isEdited || !widget.isShipped) ...[
                const SizedBox(width: kSp2),
                SlotStatusBadge(
                  isEdited: widget.isEdited,
                  isShipped: widget.isShipped,
                ),
              ],
            ],
          ),
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
