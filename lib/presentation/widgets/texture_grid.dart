import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
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
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(genre.name,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            'Slots in this genre that will be written to the mod pak.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
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
          child: Text(
            'No custom slots for this genre.\n\n'
            'The mod pak leaves the base game’s movies untouched here.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        // Card aspect: 0.5 cover + ~80px metadata strip → tweak by trial.
        childAspectRatio: 0.55,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
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
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image takes whatever vertical space is left after the metadata
          // strip claims its natural height.  AspectRatio still tries for
          // 1:2 cover shape — if the cell is too short for that, the image
          // is just letter-boxed centre.  Avoids the column overflow that
          // would happen with a hard 1:2 ratio inside a fixed-aspect cell.
          Expanded(
            child: AspectRatio(
              aspectRatio: 1024 / 2048, // matches T_Bkg dimensions
              child: _Thumbnail(replacement: replacement),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  slot.pnName.isEmpty ? '(untitled)' : slot.pnName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  slot.bkgTex,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                if (slot.sku != 0)
                  Text(
                    'SKU ${slot.sku}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
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
    final scheme = Theme.of(context).colorScheme;
    final bg = isError ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final fg = isError ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Container(
      color: bg,
      padding: const EdgeInsets.all(8),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
              isError
                  ? Icons.broken_image_outlined
                  : Icons.image_not_supported_outlined,
              color: fg),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            sublabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Could not load slot data: $message',
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}
