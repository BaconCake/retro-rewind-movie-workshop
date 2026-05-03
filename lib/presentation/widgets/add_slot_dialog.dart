import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/custom_slot_naming.dart';
import '../../domain/sku.dart';
import '../providers/providers.dart';
import 'rarity_picker.dart';
import 'star_rating_picker.dart';

/// Modal "Add Movie Slot" dialog — port of RR_VHS_Tool.py:12679-12810.
///
/// Fields:
///   * Genre   — dropdown of every non-hidden genre. Pre-selected when
///               opened from a genre tab.
///   * Title   — required, max 50 UTF-8 bytes (Python's enforced cap).
///   * Stars   — full StarRatingPicker (4.5★ default, matching Python).
///   * Rarity  — full RarityPicker (Common default).
///
/// Live "Slots used X/Y" indicator under the genre picker so the user sees
/// the cap before hitting Add. On success, the new slot is selected and
/// the dialog returns.
class AddSlotDialog extends ConsumerStatefulWidget {
  /// Genre to pre-select. Null means "All Movies" tab — picker defaults
  /// to the first non-hidden genre.
  final GenreInfo? initialGenre;

  const AddSlotDialog({super.key, this.initialGenre});

  /// Convenience launcher; returns the new slot's bkgTex on success.
  static Future<String?> show(
    BuildContext context, {
    GenreInfo? initialGenre,
  }) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AddSlotDialog(initialGenre: initialGenre),
    );
  }

  @override
  ConsumerState<AddSlotDialog> createState() => _AddSlotDialogState();
}

class _AddSlotDialogState extends ConsumerState<AddSlotDialog> {
  late GenreInfo _genre =
      widget.initialGenre ?? _selectableGenres.first;
  final _titleCtrl = TextEditingController();
  // Default star/rarity match Python's _add_movie_slot defaults (4.5★ / Common).
  double _stars = 4.5;
  Rarity _rarity = Rarity.common;
  bool _busy = false;
  String? _error;

  static List<GenreInfo> get _selectableGenres =>
      [for (final g in kGenres) if (!kHiddenGenres.contains(g.name)) g];

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    final t = _titleCtrl.text.trim();
    if (t.isEmpty) return 'Please enter a movie title.';
    if (utf8.encode(t).length > 50) {
      return 'Title must be 50 characters or less.';
    }
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final newTex = await ref.read(slotsControllerProvider).addSlot(
          genre: _genre,
          title: _titleCtrl.text.trim(),
          last2: starsToLast2(_stars),
          rarity: _rarity,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (newTex == null) {
      setState(() => _error = 'Could not add slot to ${_genre.name}.');
      return;
    }
    // Auto-select the new slot + jump to its tab.
    ref.read(selectedTabProvider.notifier).state = _genre.name;
    ref.read(selectedSlotBkgProvider.notifier).state = newTex;
    Navigator.of(context).pop(newTex);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kColorPanel,
      shape: const RoundedRectangleBorder(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(kSp4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '+  ADD MOVIE SLOT',
                style: const TextStyle(
                  fontSize: kFsApp,
                  fontWeight: FontWeight.w700,
                  color: kColorPink,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: kSp4),
              _Label('GENRE'),
              DropdownButtonFormField<GenreInfo>(
                initialValue: _genre,
                isDense: true,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true),
                style: const TextStyle(fontSize: kFsBody, color: kColorText),
                dropdownColor: kColorPanel,
                items: [
                  for (final g in _selectableGenres)
                    DropdownMenuItem(value: g, child: Text(g.name)),
                ],
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null) setState(() => _genre = v);
                      },
              ),
              const SizedBox(height: 4),
              _CapacityHint(genre: _genre),
              const SizedBox(height: kSp3),
              _Label('TITLE'),
              TextField(
                controller: _titleCtrl,
                autofocus: true,
                maxLength: 50,
                enabled: !_busy,
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                ),
                style: const TextStyle(fontSize: kFsBody, color: kColorText),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: kSp3),
              _Label('STAR RATING'),
              const SizedBox(height: kSp1),
              StarRatingPicker(
                value: _stars,
                onChanged: (v) => setState(() => _stars = v),
              ),
              const SizedBox(height: kSp3),
              _Label('RARITY'),
              const SizedBox(height: kSp1),
              RarityPicker(
                value: _rarity,
                onChanged: (r) => setState(() => _rarity = r),
              ),
              if (_error != null) ...[
                const SizedBox(height: kSp3),
                Container(
                  padding: const EdgeInsets.all(kSp2),
                  decoration: BoxDecoration(
                    color: kColorPanel,
                    border: Border.all(color: kColorPink),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                        color: kColorPink, fontSize: kFsMeta),
                  ),
                ),
              ],
              const SizedBox(height: kSp4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kColorText2,
                        side: const BorderSide(color: kColorBorder),
                        shape: const RoundedRectangleBorder(),
                      ),
                      child: const Text('CANCEL'),
                    ),
                  ),
                  const SizedBox(width: kSp2),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _submit,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.check, size: 16),
                      label: Text(_busy ? 'ADDING…' : 'ADD SLOT'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: kFsMeta,
          color: kColorText3,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Live "X/999 used (N custom, M remaining)" hint under the genre picker.
/// Mirrors Python's `_update_slot_info` — RR_VHS_Tool.py:12716-12731.
class _CapacityHint extends ConsumerWidget {
  final GenreInfo genre;

  const _CapacityHint({required this.genre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(customSlotsProvider).maybeWhen(
          data: (m) => m,
          orElse: () => const {},
        );
    final used = (slots[genre.dataTableName] ?? const []).length;
    final remaining = kBkgMax - used;
    final color = remaining > 50
        ? kColorText3
        : remaining > 0
            ? const Color(0xFFFFAA00)
            : kColorPink;
    return Text(
      'Slots: $used / $kBkgMax  ·  $remaining remaining',
      style: TextStyle(fontSize: kFsMeta, color: color),
    );
  }
}
