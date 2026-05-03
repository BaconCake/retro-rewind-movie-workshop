import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/sku.dart';
import '../providers/providers.dart';
import 'rarity_picker.dart';
import 'star_rating_picker.dart';

/// Right-hand operations column.
///
/// Mirrors Python's right-side options panel (RR_VHS_Tool.py:7702-7950).
/// Top section: per-slot options when a slot is selected (read-only for
/// slice 4a — slice 4b will turn these into editable controls).
/// Bottom section: SHIP TO STORE button + build log + error banner.
///
/// The build button stays anchored at the bottom for now, matching Python's
/// "primary action lives at the bottom of the right rail" rule. We can
/// promote it to a top-bar action in a later slice.
class SlotOptionsPanel extends ConsumerWidget {
  const SlotOptionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 360,
      color: kColorPanel,
      padding: const EdgeInsets.all(kSp3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          _SectionHeader('SLOT OPTIONS'),
          SizedBox(height: kSp2),
          Expanded(child: _SlotOptionsBody()),
          SizedBox(height: kSp3),
          _BuildSection(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: kFsMeta,
        fontWeight: FontWeight.w700,
        color: kColorCyan,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _SlotOptionsBody extends ConsumerWidget {
  const _SlotOptionsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBkg = ref.watch(selectedSlotBkgProvider);
    if (selectedBkg == null) {
      return const _EmptyOptions();
    }

    final slots = ref.watch(customSlotsProvider).maybeWhen(
          data: (m) => m,
          orElse: () => const <String, List<SlotData>>{},
        );
    final replacements = ref.watch(replacementsProvider).maybeWhen(
          data: (m) => m,
          orElse: () => const {},
        );

    final slot = _findSlot(slots, selectedBkg);
    if (slot == null) {
      return const _EmptyOptions();
    }
    final repl = replacements[slot.bkgTex];

    // Re-key the form on the slot identity so child TextField controllers
    // reset when the user picks a different slot (otherwise they'd hold
    // the previous slot's value).
    return SingleChildScrollView(
      child: KeyedSubtree(
        key: ValueKey('slot-form-${slot.bkgTex}'),
        child: _SlotForm(slot: slot, allSlots: slots, repl: repl),
      ),
    );
  }

  SlotData? _findSlot(Map<String, List<SlotData>> byDt, String bkgTex) {
    for (final list in byDt.values) {
      for (final s in list) {
        if (s.bkgTex == bkgTex) return s;
      }
    }
    return null;
  }
}

/// Editable per-slot form. Lives below the section header. Layout matches
/// Python's slot-edit dialog (RR_VHS_Tool.py:12935-13000):
///   * Title          — editable text
///   * Texture        — read-only (slot identity)
///   * Subject        — read-only (auto-generated)
///   * Layout Style   — dropdown 1..5
///   * Layout Color   — dropdown 1..10
///   * Star Rating    — dropdown (kStarOptions); changing it regenerates SKU
///   * Rarity         — dropdown (Rarity.all);   changing it regenerates SKU
///   * SKU            — read-only preview (number + skuDisplay summary)
class _SlotForm extends ConsumerWidget {
  final SlotData slot;
  final Map<String, List<SlotData>> allSlots;
  final dynamic repl; // TextureReplacement?, kept loose to avoid import noise

  const _SlotForm({
    required this.slot,
    required this.allSlots,
    required this.repl,
  });

  /// 3-digit slot index from `T_Bkg_<code>_<num>` — what generateSku wants.
  /// Falls back to 1 if the name doesn't end in digits (shouldn't happen
  /// for any well-formed slot, but defensive against hand-edited JSON).
  int _slotIndexOf(String bkgTex) {
    final m = RegExp(r'_(\d+)$').firstMatch(bkgTex);
    return m == null ? 1 : int.parse(m.group(1)!);
  }

  /// SKUs already in use across every genre, with the current slot's SKU
  /// excluded — so generateSku won't refuse to keep the current value when
  /// the user re-picks the same star/rarity.
  Set<int> _usedSkusExcludingSelf() {
    final s = <int>{};
    for (final list in allSlots.values) {
      for (final entry in list) {
        if (entry.bkgTex != slot.bkgTex && entry.sku != 0) s.add(entry.sku);
      }
    }
    return s;
  }

  /// Decode the slot's SKU into the half-star rating the picker shows.
  /// Mirrors Python's `sku_to_info` (RR_VHS_Tool.py:1869-1880).
  double _currentStars() => skuToInfo(slot.sku).stars;

  Future<void> _commitTitle(WidgetRef ref, String v) async {
    if (v == slot.pnName) return;
    await ref.read(slotsControllerProvider).updateSlot(
          slot.copyWith(pnName: v),
        );
  }

  Future<void> _regenerateSku(
    WidgetRef ref, {
    required int last2,
    required Rarity rarity,
  }) async {
    final genre = parseGenreFromTextureName(slot.bkgTex);
    final newSku = generateSku(
      genre: genre?.dataTableName ?? 'Drama',
      slotIndex: _slotIndexOf(slot.bkgTex),
      last2: last2,
      rarity: rarity,
      usedSkus: _usedSkusExcludingSelf(),
    );
    if (newSku == slot.sku) return;
    await ref.read(slotsControllerProvider).updateSlot(
          slot.copyWith(sku: newSku),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentStars = _currentStars();
    final currentRarity = skuToRarity(slot.sku);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SlotTextField(
          label: 'Title',
          initialValue: slot.pnName,
          onCommit: (v) => _commitTitle(ref, v),
        ),
        _OptionRow(label: 'Texture', value: slot.bkgTex),
        if (slot.subTex != null)
          _OptionRow(label: 'Subject', value: slot.subTex!),
        const SizedBox(height: kSp2),
        const _SubHeader('STAR RATING'),
        const SizedBox(height: kSp1),
        StarRatingPicker(
          value: currentStars,
          onChanged: (stars) => _regenerateSku(
            ref,
            last2: starsToLast2(stars),
            rarity: currentRarity,
          ),
        ),
        const SizedBox(height: kSp3),
        const _SubHeader('RARITY'),
        const SizedBox(height: kSp1),
        RarityPicker(
          value: currentRarity,
          onChanged: (r) => _regenerateSku(
            ref,
            last2: starsToLast2(currentStars),
            rarity: r,
          ),
        ),
        const SizedBox(height: kSp3),
        const _SubHeader('CATALOG ID'),
        const SizedBox(height: kSp1),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '${slot.sku}',
                style: const TextStyle(fontSize: kFsBody, color: kColorText),
              ),
            ),
            IconButton(
              tooltip: 'Copy catalog ID',
              visualDensity: VisualDensity.compact,
              color: kColorText2,
              icon: const Icon(Icons.content_copy, size: 14),
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: '${slot.sku}'));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Catalog ID copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ],
        ),
        Text(
          skuDisplay(slot.sku),
          style: const TextStyle(fontSize: kFsMeta, color: kColorText3),
        ),
        const SizedBox(height: kSp3),
        const _SubHeader('USER IMAGE'),
        const SizedBox(height: kSp2),
        _UserImageControls(
          bkgTex: slot.bkgTex,
          currentPath: repl?.path as String?,
        ),
      ],
    );
  }
}

/// Sub-header inside the slot form (e.g. STAR RATING / RARITY / CATALOG ID).
/// Same visual treatment as [_SectionHeader] but distinct widget so the
/// outer "SLOT OPTIONS" header keeps its top-of-panel role.
class _SubHeader extends StatelessWidget {
  final String label;
  const _SubHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: kFsMeta,
        fontWeight: FontWeight.w700,
        color: kColorCyan,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  final String label;
  final String value;

  const _OptionRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kSp2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: kFsMeta,
              color: kColorText3,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontSize: kFsBody, color: kColorText),
          ),
        ],
      ),
    );
  }
}

/// Editable string field. Commits on Enter and on focus loss; skips the
/// commit when the value is unchanged so we don't churn the file on every
/// focus shuffle.
class _SlotTextField extends StatefulWidget {
  final String label;
  final String initialValue;
  final ValueChanged<String> onCommit;

  const _SlotTextField({
    required this.label,
    required this.initialValue,
    required this.onCommit,
  });

  @override
  State<_SlotTextField> createState() => _SlotTextFieldState();
}

class _SlotTextFieldState extends State<_SlotTextField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialValue);
  late String _lastCommitted = widget.initialValue;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _commit() {
    final next = _ctrl.text;
    if (next == _lastCommitted) return;
    _lastCommitted = next;
    widget.onCommit(next);
  }

  @override
  Widget build(BuildContext context) {
    return _FieldShell(
      label: widget.label,
      child: TextField(
        controller: _ctrl,
        decoration: const InputDecoration(isDense: true),
        style: const TextStyle(fontSize: kFsBody, color: kColorText),
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) => _commit(),
      ),
    );
  }
}

/// Caps-label above, child input below — keeps the editable rows visually
/// flush with the read-only [_OptionRow]s above them.
class _FieldShell extends StatelessWidget {
  final String label;
  final Widget child;

  const _FieldShell({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kSp2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: kFsMeta,
              color: kColorText3,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }
}

class _EmptyOptions extends StatelessWidget {
  const _EmptyOptions();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: kSp3),
      child: Text(
        '(select a slot to see its options)',
        style: TextStyle(fontSize: kFsMeta, color: kColorText3),
      ),
    );
  }
}

/// Upload / replace / remove controls for the per-slot user image.
///
/// "Upload" / "Replace" opens an OS file picker constrained to common
/// raster formats; the chosen path is written to `replacements.json` via
/// [ReplacementsController.setImage]. "Remove" deletes the entry — the
/// slot will then render as a black placeholder in-game.
class _UserImageControls extends ConsumerStatefulWidget {
  final String bkgTex;
  final String? currentPath;

  const _UserImageControls({required this.bkgTex, this.currentPath});

  @override
  ConsumerState<_UserImageControls> createState() =>
      _UserImageControlsState();
}

class _UserImageControlsState extends ConsumerState<_UserImageControls> {
  bool _busy = false;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        dialogTitle: 'Pick cover image for ${widget.bkgTex}',
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;
      await ref
          .read(replacementsControllerProvider)
          .setImage(widget.bkgTex, path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(replacementsControllerProvider)
          .removeImage(widget.bkgTex);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.currentPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasImage)
          Padding(
            padding: const EdgeInsets.only(bottom: kSp2),
            child: Text(
              widget.currentPath!,
              style: const TextStyle(fontSize: kFsMeta, color: kColorText2),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(bottom: kSp2),
            child: Text(
              '(no image — slot will render black in-game)',
              style: TextStyle(fontSize: kFsMeta, color: kColorText3),
            ),
          ),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: Icon(
                hasImage ? Icons.swap_horiz : Icons.upload_file_outlined,
                size: 16,
              ),
              label: Text(hasImage ? 'REPLACE' : 'UPLOAD'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kColorPink,
                side: const BorderSide(color: kColorPink),
                shape: const RoundedRectangleBorder(),
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(
                  fontSize: kFsMeta,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: kSp2),
            if (hasImage)
              IconButton(
                onPressed: _busy ? null : _remove,
                tooltip: 'Remove image',
                visualDensity: VisualDensity.compact,
                color: kColorText2,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
          ],
        ),
      ],
    );
  }
}

class _BuildSection extends ConsumerWidget {
  const _BuildSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(buildControllerProvider);
    final controller = ref.read(buildControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: state.isRunning ? null : controller.ship,
          icon: state.isRunning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.local_shipping_outlined, size: 18),
          label: Text(
            state.isRunning ? 'BUILDING...' : 'SHIP TO STORE',
            style: const TextStyle(letterSpacing: 1.5),
          ),
        ),
        const SizedBox(height: kSp3),
        Row(
          children: [
            const Expanded(
              child: Text(
                'BUILD LOG',
                style: TextStyle(
                  fontSize: kFsMeta,
                  fontWeight: FontWeight.w700,
                  color: kColorCyan,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy log to clipboard',
              visualDensity: VisualDensity.compact,
              color: kColorText2,
              icon: const Icon(Icons.content_copy, size: 14),
              onPressed: state.log.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(
                          ClipboardData(text: state.log.join('\n')));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Log copied to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
        const SizedBox(height: kSp1),
        SizedBox(
          height: 180,
          child: Container(
            decoration: BoxDecoration(
              color: kColorBg,
              border: Border.all(color: kColorBorder),
            ),
            padding: const EdgeInsets.all(kSp2),
            child: ListView.builder(
              itemCount: state.log.length,
              itemBuilder: (context, i) {
                final line = state.log[i];
                return Text(
                  line,
                  style: TextStyle(
                    fontSize: kFsMeta,
                    color: _logLineColor(line),
                    height: 1.3,
                  ),
                );
              },
            ),
          ),
        ),
        if (state.lastErrorCode != null) ...[
          const SizedBox(height: kSp2),
          Container(
            padding: const EdgeInsets.all(kSp2),
            decoration: BoxDecoration(
              color: kColorPanel,
              border: Border.all(color: kColorPink),
            ),
            child: Text(
              '[${state.lastErrorCode}] ${state.lastErrorMessage}',
              style: const TextStyle(color: kColorPink, fontSize: kFsMeta),
            ),
          ),
        ],
      ],
    );
  }

  Color _logLineColor(String line) {
    final l = line.toUpperCase();
    if (l.contains('FAIL') || l.contains('ERROR') || l.contains('[E0')) {
      return kColorPink;
    }
    if (l.contains(' OK') ||
        l.contains('INJECT ') ||
        l.contains('PLACEHOLDER ') ||
        l.contains('SUCCEEDED') ||
        l.contains('INSTALLED')) {
      return kColorCyan;
    }
    return kColorText2;
  }
}
