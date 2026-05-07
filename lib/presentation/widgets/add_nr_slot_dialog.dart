import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/new_release.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/nr_slot_logic.dart';
import '../providers/providers.dart';

/// Genre-picker dialog for adding a New Release slot.
///
/// Mirrors Python's `_add_new_release` (RR_VHS_Tool.py:9132-9195): a
/// scrollable list of NR-eligible genres only (so Adventure / Adult are
/// hidden — they have no base game T_New textures).  On select, calls
/// [NrSlotsController.addSlot] and selects the new slot in the shelf.
///
/// Per-genre cap (99) is enforced upstream by `addNrSlot` and surfaced as a
/// SnackBar reading "X already has the maximum of 99 New Releases" so the
/// user knows to delete one first or pick a different genre.
class AddNrSlotDialog extends ConsumerWidget {
  const AddNrSlotDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const Dialog(
        backgroundColor: kColorPanel,
        child: AddNrSlotDialog(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 540),
      child: Padding(
        padding: const EdgeInsets.all(kSp3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'NEW RELEASE — CHOOSE GENRE',
              style: TextStyle(
                fontSize: kFsBody,
                fontWeight: FontWeight.w700,
                color: kColorCyan,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: kSp1),
            const Text(
              'Only genres with base-game NR textures are listed.',
              style: TextStyle(fontSize: kFsMeta, color: kColorText3),
            ),
            const SizedBox(height: kSp3),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final g in kNrGenres)
                      _GenreRow(
                        genre: g,
                        onTap: () => _addAndDismiss(context, ref, g),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: kSp3),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'CANCEL',
                  style: TextStyle(
                    fontSize: kFsMeta,
                    color: kColorText3,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addAndDismiss(
      BuildContext context, WidgetRef ref, String genre) async {
    final result =
        await ref.read(nrSlotsControllerProvider).addSlot(genre: genre);
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (result.isOk) {
      // Select the new slot so its options panel opens immediately.
      ref.read(selectedSlotBkgProvider.notifier).state =
          'nr:${result.slot!.sku}';
      return;
    }

    final msg = switch (result.error!) {
      AddNrError.unsupportedGenre =>
        "'$genre' has no base game NR textures.",
      AddNrError.perGenreCapReached =>
        "'$genre' already has the maximum of "
            '$kNrPerGenreCap New Releases. Delete one first or pick '
            'a different genre.',
      AddNrError.skuExhausted =>
        'Could not allocate a unique SKU — every value in '
            '$kNrSkuMin..$kNrSkuMax is taken.',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: kColorPanel,
      content: Text(msg, style: const TextStyle(color: kColorPink)),
    ));
  }
}

class _GenreRow extends StatelessWidget {
  final String genre;
  final VoidCallback onTap;
  const _GenreRow({required this.genre, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: kSp3, vertical: kSp2),
          decoration: BoxDecoration(
            color: kColorBg,
            border: Border.all(color: kColorBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  genre,
                  style: const TextStyle(
                    fontSize: kFsBody,
                    color: kColorText,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: kColorText3, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
