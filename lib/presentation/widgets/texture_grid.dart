import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';

/// Read-only grid of the custom slots configured for [genre].  Shows what
/// would land in the next `Ship to Store` build, sourced from
/// `custom_slots.json` (slot list + metadata) and `replacements.json`
/// (per-slot user image).
///
/// Slice 4a scope: display only.  Click-to-upload, offset/zoom, slot
/// add/remove come in 4b/4c.
class TextureGrid extends ConsumerWidget {
  final GenreInfo genre;

  const TextureGrid({super.key, required this.genre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customSlots = ref.watch(customSlotsProvider);
    final replacements = ref.watch(replacementsProvider);

    return Padding(
      padding: const EdgeInsets.all(kSp3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            genre.name.toUpperCase(),
            style: const TextStyle(
              fontSize: kFsApp,
              fontWeight: FontWeight.w700,
              color: kColorCyan,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: kSp1),
          Text(
            'Slots in this genre that will be written to the mod pak.',
            style: const TextStyle(fontSize: kFsMeta, color: kColorText3),
          ),
          const SizedBox(height: kSp3),
          Expanded(
            child: customSlots.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, st) => _ErrorBanner(message: '$e'),
              data: (slotsByDt) => replacements.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, st) => _ErrorBanner(message: '$e'),
                data: (replMap) => _SlotGrid(
                  slots: slotsByDt[genre.dataTableName] ?? const [],
                  replacements: replMap,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlotGrid extends StatelessWidget {
  final List<SlotData> slots;
  final Map<String, TextureReplacement> replacements;

  const _SlotGrid({required this.slots, required this.replacements});

  @override
  Widget build(BuildContext context) {
    if (slots.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: const Text(
            'NO CUSTOM SLOTS\n\n'
            'The mod pak leaves the base game’s movies untouched here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: kFsBody,
              color: kColorText3,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    return GridView.builder(
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
        );
      },
    );
  }
}

class _SlotCard extends StatelessWidget {
  final SlotData slot;
  final TextureReplacement? replacement;

  const _SlotCard({required this.slot, this.replacement});

  @override
  Widget build(BuildContext context) {
    final hasImage = replacement != null;
    // Outer border: pink accent if a custom image is wired up (matches
    // Python's "list row custom" rule), neutral border otherwise.
    final borderColor = hasImage ? kColorPink : kColorBorder;
    return Container(
      decoration: BoxDecoration(
        color: kColorPanel,
        border: Border.all(color: borderColor),
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
      return _Placeholder(
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
    // cacheWidth keeps decoded bitmap small; full-res posters can be 4-10 MB
    // each and we may show 20+ at once.
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
