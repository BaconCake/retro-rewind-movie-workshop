import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';

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
      return const _CenteredHint(
        title: 'NEW RELEASES',
        body: 'Coming in slice 5 — NR support is deferred for now.',
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (slots.isEmpty) {
      return const _CenteredHint(
        title: 'NO CUSTOM SLOTS',
        body: 'The mod pak leaves the base game’s movies untouched here.',
      );
    }

    final selectedBkg = ref.watch(selectedSlotBkgProvider);

    return GridView.builder(
      padding: const EdgeInsets.all(kSp3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.55,
        crossAxisSpacing: kSp3,
        mainAxisSpacing: kSp3,
      ),
      itemCount: slots.length,
      itemBuilder: (context, i) {
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
              child: AspectRatio(
                aspectRatio: 1024 / 2048,
                child: _Thumbnail(replacement: replacement),
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

class _Thumbnail extends StatelessWidget {
  final TextureReplacement? replacement;

  const _Thumbnail({this.replacement});

  @override
  Widget build(BuildContext context) {
    final r = replacement;
    if (r == null) {
      return const _Placeholder(
        label: 'NO IMAGE',
        sublabel: 'will render black in-game',
      );
    }
    final file = File(r.path);
    if (!file.existsSync()) {
      return _Placeholder(
        label: 'IMAGE MISSING',
        sublabel: r.path,
        isError: true,
      );
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: 360,
      errorBuilder: (context, error, stack) => _Placeholder(
        label: 'DECODE ERROR',
        sublabel: r.path,
        isError: true,
      ),
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

class _CenteredHint extends StatelessWidget {
  final String title;
  final String body;

  const _CenteredHint({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(kSp4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: kFsBody,
                  fontWeight: FontWeight.w700,
                  color: kColorText3,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: kSp2),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: kFsMeta,
                  color: kColorText3,
                  height: 1.4,
                ),
              ),
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
