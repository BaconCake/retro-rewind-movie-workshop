import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/genres.dart';
import '../../core/constants/new_release.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/status_pill.dart';
import '../../core/widgets/focus_bloom.dart';
import '../../core/widgets/phosphor_build_log.dart';
import '../../core/widgets/primary_button.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/nr_slot_logic.dart';
import '../../domain/repositories/pak_builder.dart' show BuildProgress;
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
          _SlotOptionsHeader(),
          SizedBox(height: kSp2),
          Expanded(child: _SlotOptionsBody()),
          SizedBox(height: kSp3),
          _BuildSection(),
        ],
      ),
    );
  }
}

/// Header row above the slot edit form.  Shows the cyan "SLOT OPTIONS"
/// label on the left and, when a slot is selected, its build-status
/// badge on the right (same EDITED/UNSHIPPED semantics as the shelf
/// cards — central place for the user to see status while editing).
class _SlotOptionsHeader extends ConsumerWidget {
  const _SlotOptionsHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSlotBkgProvider);
    String? trackingKey;
    if (selected != null) {
      if (selected.startsWith(kNrSelectionPrefix)) {
        final sku = selected.substring(kNrSelectionPrefix.length);
        if (int.tryParse(sku) != null) trackingKey = 'NR_$sku';
      } else {
        trackingKey = selected; // genre slot key == bkgTex
      }
    }
    final tracking = ref.watch(trackingProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const _SectionHeader('SLOT OPTIONS'),
        if (trackingKey != null)
          SlotStatusPill(
            isEdited: tracking.edited.contains(trackingKey),
            isShipped: tracking.shipped.contains(trackingKey),
          ),
      ],
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

    // NR slots are routed through a separate form — different fields than
    // genre slots, but the replacements.json mechanism is reused (same key:
    // texture name).  The cover image is optional; without one the engine
    // falls back to the base-game NR texture.
    if (selectedBkg.startsWith(kNrSelectionPrefix)) {
      final sku =
          int.tryParse(selectedBkg.substring(kNrSelectionPrefix.length));
      if (sku == null) return const _EmptyOptions();
      final nrAsync = ref.watch(nrSlotsProvider);
      final replacements = ref.watch(replacementsProvider).maybeWhen(
            data: (m) => m,
            orElse: () => const {},
          );
      return nrAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _EmptyOptions(error: '$e'),
        data: (slots) {
          NewReleaseSlot? nr;
          for (final s in slots) {
            if (s.sku == sku) {
              nr = s;
              break;
            }
          }
          if (nr == null) return const _EmptyOptions();
          final repl = replacements[nr.bkgTex];
          return SingleChildScrollView(
            child: KeyedSubtree(
              key: ValueKey('nr-form-${nr.sku}'),
              child: _NrSlotForm(slot: nr, allSlots: slots, repl: repl),
            ),
          );
        },
      );
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
        const SizedBox(height: kSp4),
        _DeleteSlotLink(slot: slot),
      ],
    );
  }
}

/// Demoted destructive action — small red text link, matching Python's
/// "Delete This Movie" `tk.Label` (RR_VHS_Tool.py:8879-8890). Confirms
/// before calling [SlotsController.removeSlot].
class _DeleteSlotLink extends ConsumerStatefulWidget {
  final SlotData slot;
  const _DeleteSlotLink({required this.slot});

  @override
  ConsumerState<_DeleteSlotLink> createState() => _DeleteSlotLinkState();
}

class _DeleteSlotLinkState extends ConsumerState<_DeleteSlotLink> {
  bool _hover = false;

  Future<void> _confirmAndDelete() async {
    final title = widget.slot.pnName.isEmpty
        ? widget.slot.bkgTex
        : widget.slot.pnName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kColorPanel,
        shape: const RoundedRectangleBorder(),
        title: const Text('Delete movie'),
        content: Text(
          'Delete "$title"?\nThis cannot be undone.',
          style: const TextStyle(color: kColorText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL'),
          ),
          PrimaryButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            label: 'DELETE',
            compact: true,
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(slotsControllerProvider)
        .removeSlot(widget.slot.bkgTex);
    // Clear the selection so the right rail goes back to the empty state.
    if (mounted) {
      ref.read(selectedSlotBkgProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _confirmAndDelete,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          child: Text(
            'Delete this movie',
            style: TextStyle(
              fontSize: kFsMeta,
              color:
                  _hover ? const Color(0xFFFF6666) : const Color(0xFF994444),
              decoration: _hover ? TextDecoration.underline : null,
            ),
          ),
        ),
      ),
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
      child: FocusBloom(
        child: TextField(
          controller: _ctrl,
          decoration: const InputDecoration(isDense: true),
          style: const TextStyle(fontSize: kFsBody, color: kColorText),
          onSubmitted: (_) => _commit(),
          onTapOutside: (_) => _commit(),
        ),
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
  final String? error;
  const _EmptyOptions({this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSp3),
      child: Text(
        error ?? '(select a slot to see its options)',
        style: TextStyle(
          fontSize: kFsMeta,
          color: error != null ? kColorPink : kColorText3,
        ),
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

    // Fire a SnackBar exactly once on the running → success transition so
    // the user gets a clear "done" signal even when their attention is
    // elsewhere.  Failures keep using the inline pink error box below
    // since they need a stickier presentation.
    ref.listen<BuildState>(buildControllerProvider, (prev, next) {
      if (prev?.isRunning == true && !next.isRunning &&
          next.lastBuildSucceeded) {
        final elapsed = next.lastBuildElapsedMs != null
            ? '${(next.lastBuildElapsedMs! / 1000).toStringAsFixed(1)}s'
            : '?s';
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            backgroundColor: kColorPanel,
            duration: const Duration(seconds: 5),
            content: Text(
              '✓ BUILD DONE — pak shipped in $elapsed',
              style: const TextStyle(
                  color: kColorCyan,
                  fontFamily: kFontFamily,
                  fontSize: kFsBody,
                  letterSpacing: 1),
            ),
          ));
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LN-7: PrimaryButton — bloom on hover, darken on press,
        // outlined-ghost when running so the user gets a clear
        // "I'm busy, hands off" cue without the button looking dead.
        PrimaryButton(
          onPressed: state.isRunning ? null : controller.ship,
          icon: state.isRunning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  state.lastBuildSucceeded
                      ? Icons.check_circle_outline
                      : Icons.local_shipping_outlined,
                  size: 18,
                ),
          label: state.isRunning
              ? 'BUILDING...'
              : state.lastBuildSucceeded
                  ? 'SHIP AGAIN'
                  : 'SHIP TO STORE',
        ),
        if (state.isRunning && state.progress != null) ...[
          const SizedBox(height: kSp2),
          _BuildProgressBar(progress: state.progress!),
        ],
        if (!state.isRunning && state.lastBuildSucceeded) ...[
          const SizedBox(height: kSp2),
          _BuildSuccessBanner(state: state),
        ],
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
        // LN-9: phosphor-terminal styled log surface — warm-black bg,
        // amber/lime/pink text with per-line bloom, scanline veil.
        SizedBox(
          height: 180,
          child: PhosphorBuildLog(
            lines: state.log,
            running: state.isRunning,
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

}

/// Determinate progress bar shown while a build is running.  Each unit
/// in [BuildProgress] is one observable thing the build did (a slot
/// inject, a DataTable write, a standee asset, etc.) so the bar fills
/// proportionally to actual time spent — not just to a single phase.
class _BuildProgressBar extends StatelessWidget {
  final BuildProgress progress;
  const _BuildProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.zero,
          child: LinearProgressIndicator(
            value: progress.fraction,
            backgroundColor: kColorSurface,
            valueColor: const AlwaysStoppedAnimation(kColorCyan),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: kSp1),
        Row(
          children: [
            Text(
              '${progress.current}/${progress.total}',
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: kFsMeta,
                color: kColorCyan,
              ),
            ),
            const SizedBox(width: kSp2),
            Expanded(
              child: Text(
                progress.label,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: kFsMeta,
                  color: kColorText3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Cyan banner showing the most recent successful build's outcome —
/// elapsed time + pak size + install path.  Stays visible until the next
/// ship() resets the state.
class _BuildSuccessBanner extends StatelessWidget {
  final BuildState state;
  const _BuildSuccessBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final elapsed = state.lastBuildElapsedMs != null
        ? '${(state.lastBuildElapsedMs! / 1000).toStringAsFixed(1)}s'
        : '?s';
    final size = state.lastPakSizeBytes != null
        ? '${(state.lastPakSizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '?';
    final installed = state.lastInstalledPath ?? '(not installed)';
    return Container(
      padding: const EdgeInsets.all(kSp2),
      decoration: BoxDecoration(
        color: kColorPanel,
        border: Border.all(color: kColorCyan, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: kColorCyan, size: 16),
              const SizedBox(width: kSp2),
              Text(
                'DONE in $elapsed · $size',
                style: const TextStyle(
                  color: kColorCyan,
                  fontFamily: kFontFamily,
                  fontSize: kFsBody,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: kSp1),
          Text(
            installed,
            style: const TextStyle(
              color: kColorText3,
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// New Release editor — title, genre button-grid, standee shape A/B/C,
/// delete.  Mirrors Python's NR controls frame (RR_VHS_Tool.py:9197-9311).
///
/// Edits commit immediately to `nr_custom_slots.json` via [NrSlotsController].
/// Genre changes go through [changeNrSlotGenre] so `texNum` and `bkgTex`
/// stay consistent with the new genre's available T_New textures.
class _NrSlotForm extends ConsumerWidget {
  final NewReleaseSlot slot;
  final List<NewReleaseSlot> allSlots;
  // TextureReplacement?; kept loose to avoid pulling the import here, mirroring
  // _SlotForm above.
  final dynamic repl;

  const _NrSlotForm(
      {required this.slot, required this.allSlots, this.repl});

  Future<void> _commitTitle(WidgetRef ref, String v) async {
    if (v == slot.title) return;
    await ref
        .read(nrSlotsControllerProvider)
        .updateSlot(slot.copyWith(title: v));
  }

  Future<void> _setGenre(BuildContext context, WidgetRef ref,
      String newGenre) async {
    if (newGenre == slot.genre) return;
    final updated = changeNrSlotGenre(
      slot: slot,
      newGenre: newGenre,
      allSlots: allSlots,
    );
    if (updated == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: kColorPanel,
          content: Text("Cannot change to '$newGenre' — not NR-eligible.",
              style: const TextStyle(color: kColorPink)),
        ));
      }
      return;
    }
    await ref.read(nrSlotsControllerProvider).updateSlot(updated);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SlotTextField(
          label: 'Title',
          initialValue: slot.title,
          onCommit: (v) => _commitTitle(ref, v),
        ),
        _OptionRow(label: 'Texture', value: slot.bkgTex),
        const SizedBox(height: kSp3),
        const _SubHeader('STANDEE SHAPE'),
        const SizedBox(height: kSp2),
        _NrShapeCardRow(slot: slot),
        const SizedBox(height: kSp3),
        const _SubHeader('GENRE'),
        const SizedBox(height: kSp1),
        _NrGenreGrid(
          current: slot.genre,
          onPick: (g) => _setGenre(context, ref, g),
        ),
        const SizedBox(height: kSp3),
        const _SubHeader('CATALOG ID'),
        const SizedBox(height: kSp1),
        Row(
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
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Catalog ID copied'),
                    duration: Duration(seconds: 1),
                  ));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: kSp3),
        const _SubHeader('USER IMAGE'),
        const SizedBox(height: kSp2),
        _UserImageControls(
          bkgTex: slot.bkgTex,
          currentPath: repl?.path as String?,
        ),
        const SizedBox(height: kSp4),
        _DeleteNrLink(slot: slot),
      ],
    );
  }
}

/// Button grid of NR-eligible genres.  Selected genre is filled cyan;
/// 3-card NR standee shape picker — A/B/C with the bundled standee
/// game-screenshot JPGs (`assets/standee_templates/standee_<shape>.jpg`).
/// Mirrors the right-column shape picker in Python's NR form
/// (RR_VHS_Tool.py:8735-8776).  Click sets the slot's [standeeShape]
/// AND auto-switches the centre preview to Standee mode (Python's
/// `_on_shape_pick`, RR_VHS_Tool.py:9306-9307).
class _NrShapeCardRow extends ConsumerWidget {
  final NewReleaseSlot slot;
  const _NrShapeCardRow({required this.slot});

  Future<void> _pick(WidgetRef ref, String shape) async {
    if (shape != slot.standeeShape) {
      await ref
          .read(nrSlotsControllerProvider)
          .updateSlot(slot.copyWith(standeeShape: shape));
    }
    ref.read(standeePreviewModeProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        for (final s in const ['A', 'B', 'C']) ...[
          Expanded(
            child: _NrShapeCard(
              shape: s,
              selected: s == slot.standeeShape,
              onTap: () => _pick(ref, s),
            ),
          ),
          if (s != 'C') const SizedBox(width: kSp2),
        ],
      ],
    );
  }
}

class _NrShapeCard extends StatelessWidget {
  final String shape;
  final bool selected;
  final VoidCallback onTap;
  const _NrShapeCard({
    required this.shape,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final asset =
        'assets/standee_templates/standee_${shape.toLowerCase()}.jpg';
    final borderColor = selected ? kColorCyan : kColorBorder;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: kColorPanel,
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Image.asset(
                asset,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  color: kColorBg,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported,
                      color: kColorText3, size: 28),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: kSp1),
              alignment: Alignment.center,
              color: selected ? kColorCyan : kColorPanel,
              child: Text(
                shape,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: kFsApp,
                  fontWeight: FontWeight.w700,
                  color: selected ? kColorTextInv : kColorText2,
                  letterSpacing: 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// others use the panel surface.  Mirrors Python's
/// `_update_nr_genre_btns` (RR_VHS_Tool.py:9215-9222).
class _NrGenreGrid extends StatelessWidget {
  final String current;
  final ValueChanged<String> onPick;

  const _NrGenreGrid({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: kSp1,
      runSpacing: kSp1,
      children: [
        for (final g in kNrGenres)
          _NrPickerButton(
            label: g,
            selected: g == current,
            onTap: () => onPick(g),
          ),
      ],
    );
  }
}

class _NrPickerButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NrPickerButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: kSp2, vertical: kSp1),
        decoration: BoxDecoration(
          color: selected ? kColorCyan : kColorPanel,
          border: Border.all(
            color: selected ? kColorCyan : kColorBorder,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: kFsMeta,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? kColorTextInv : kColorText,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

/// Delete link for NR slots — same visual treatment as [_DeleteSlotLink],
/// different controller call.
class _DeleteNrLink extends ConsumerStatefulWidget {
  final NewReleaseSlot slot;
  const _DeleteNrLink({required this.slot});

  @override
  ConsumerState<_DeleteNrLink> createState() => _DeleteNrLinkState();
}

class _DeleteNrLinkState extends ConsumerState<_DeleteNrLink> {
  bool _hover = false;

  Future<void> _confirmAndDelete() async {
    final title =
        widget.slot.title.isEmpty ? widget.slot.bkgTex : widget.slot.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kColorPanel,
        shape: const RoundedRectangleBorder(),
        title: const Text('Delete New Release'),
        content: Text(
          'Delete "$title"?\nThis cannot be undone.',
          style: const TextStyle(color: kColorText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCEL'),
          ),
          PrimaryButton.destructive(
            onPressed: () => Navigator.of(context).pop(true),
            label: 'DELETE',
            compact: true,
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(nrSlotsControllerProvider).removeSlot(widget.slot.sku);
    // removeSlot already clears the selection if the deleted slot was
    // the selected one.
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _confirmAndDelete,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          child: Text(
            'Delete this New Release',
            style: TextStyle(
              fontSize: kFsMeta,
              color:
                  _hover ? const Color(0xFFFF6666) : const Color(0xFF994444),
              decoration: _hover ? TextDecoration.underline : null,
            ),
          ),
        ),
      ),
    );
  }
}
