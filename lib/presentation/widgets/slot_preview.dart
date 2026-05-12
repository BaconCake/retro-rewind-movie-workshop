import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../data/services/cover_actions.dart';
import '../../domain/cover_quality.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';
import 'cover_drop_paste_zone.dart';
import 'cover_quality_chip.dart';
import 'crop_editor_bar.dart';
import 'cropping_preview.dart';
import 'layout_style_picker.dart';

/// Center column of the main layout: a large preview of the currently
/// selected slot's cover (or a "select a slot" hint when none is picked).
///
/// Mirrors Python's preview pane (RR_VHS_Tool.py:7565-7700) — full-bleed
/// 1024×2048 cover at the natural 1:2 aspect, centered, with the slot title
/// underneath in cyan.
class SlotPreview extends ConsumerWidget {
  const SlotPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedBkg = ref.watch(selectedSlotBkgProvider);

    if (selectedBkg == null) {
      return const CoverDropPasteZone(
          bkgTex: null, child: _EmptyState());
    }

    // NR slots are routed to a dedicated preview that supports the
    // VHS/Standee toggle and forces full-canvas crop semantics — NRs
    // don't use the layout-aware cropping that genre slots do.
    if (selectedBkg.startsWith(kNrSelectionPrefix)) {
      final sku =
          int.tryParse(selectedBkg.substring(kNrSelectionPrefix.length));
      if (sku == null) {
        return const CoverDropPasteZone(
            bkgTex: null, child: _EmptyState());
      }
      return _NrSlotPreview(sku: sku);
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
      return const CoverDropPasteZone(
          bkgTex: null, child: _EmptyState());
    }

    final repl = replacements[slot.bkgTex];

    return CoverDropPasteZone(
      bkgTex: slot.bkgTex,
      child: Padding(
      padding: const EdgeInsets.all(kSp4),
      child: Column(
        children: [
          Expanded(
            child: repl == null
                ? Center(
                    child: AspectRatio(
                      aspectRatio: 1024 / 2048,
                      child: _UploadPicker(bkgTex: slot.bkgTex),
                    ),
                  )
                : _CoverEditorBlock(
                    // Reset transient state on slot change.
                    key: ValueKey(slot.bkgTex),
                    bkgTex: slot.bkgTex,
                    layout: slot.ls,
                    replacement: repl,
                  ),
          ),
          const SizedBox(height: kSp2),
          Text(
            slot.pnName.isEmpty ? '(untitled)' : slot.pnName,
            style: const TextStyle(
              fontSize: kFsApp,
              fontWeight: FontWeight.w700,
              color: kColorCyan,
              letterSpacing: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            slot.bkgTex,
            style: const TextStyle(fontSize: kFsMeta, color: kColorText3),
          ),
          const SizedBox(height: kSp3),
          LayoutSection(
            value: slot.ls.clamp(1, 5),
            onChanged: (v) async {
              if (v == slot.ls) return;
              await ref
                  .read(slotsControllerProvider)
                  .updateSlot(slot.copyWith(ls: v));
            },
          ),
        ],
      ),
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

/// Preview pane for an NR slot.  Differs from the genre preview in three
/// ways:
///   * cropper runs in full-canvas mode and overlays the standee zone
///     lines (gold/brown title-plate / footer / frame) instead of the
///     layout-aware safe-area hatch;
///   * VHS / Standee toggle above the cover swaps in the shape-specific
///     overlay (semicircle arch for A, fold lines for B, rounded
///     corners for C) on the same cropper canvas;
///   * the layout-style picker below the cover is replaced by a 3-card
///     standee-shape picker (A/B/C) — every NR ships as one of those
///     three shapes, not as a layout 1..5.
class _NrSlotPreview extends ConsumerWidget {
  final int sku;
  const _NrSlotPreview({required this.sku});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nrAsync = ref.watch(nrSlotsProvider);
    final replacements = ref.watch(replacementsProvider).maybeWhen(
          data: (m) => m,
          orElse: () => const {},
        );

    return nrAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _PreviewPlaceholder(
          label: 'NR LOAD ERROR', sublabel: '$e', isError: true),
      data: (slots) {
        NewReleaseSlot? slot;
        for (final s in slots) {
          if (s.sku == sku) {
            slot = s;
            break;
          }
        }
        if (slot == null) {
          return const CoverDropPasteZone(
              bkgTex: null, child: _EmptyState());
        }
        final repl = replacements[slot.bkgTex];
        final standeeMode = ref.watch(standeePreviewModeProvider);
        final localSlot = slot;

        return CoverDropPasteZone(
          bkgTex: localSlot.bkgTex,
          child: Padding(
          padding: const EdgeInsets.all(kSp4),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _NrReplaceImageButton(bkgTex: localSlot.bkgTex),
                  const SizedBox(width: kSp3),
                  _VhsStandeeToggle(
                    standeeMode: standeeMode,
                    onChanged: (v) => ref
                        .read(standeePreviewModeProvider.notifier)
                        .state = v,
                  ),
                ],
              ),
              const SizedBox(height: kSp2),
              Expanded(
                child: repl == null
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: 1024 / 2048,
                          child: _UploadPicker(bkgTex: localSlot.bkgTex),
                        ),
                      )
                    : _CoverEditorBlock(
                        key: ValueKey(
                            'nr-${localSlot.bkgTex}-${localSlot.standeeShape}'),
                        bkgTex: localSlot.bkgTex,
                        layout: 1, // ignored when isNewRelease=true
                        replacement: repl,
                        isNewRelease: true,
                        nrShape: localSlot.standeeShape,
                        standeeMode: standeeMode,
                      ),
              ),
              const SizedBox(height: kSp2),
              Text(
                localSlot.title.isEmpty ? '(untitled)' : localSlot.title,
                style: const TextStyle(
                  fontSize: kFsApp,
                  fontWeight: FontWeight.w700,
                  color: kColorCyan,
                  letterSpacing: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                '${localSlot.bkgTex}  ·  shape ${localSlot.standeeShape}',
                style: const TextStyle(
                    fontSize: kFsMeta, color: kColorText3),
              ),
            ],
          ),
          ),
        );
      },
    );
  }
}

/// "PREVIEW: VHS Tape | Standee" header strip above the NR cover.
/// Content-sized so the parent Row can group it next to the Replace
/// Image button (RR_VHS_Tool.py:7766-7787 — both controls live in the
/// same `_vp_tab_inner` frame, packed left-to-right and centered).
class _VhsStandeeToggle extends StatelessWidget {
  final bool standeeMode;
  final ValueChanged<bool> onChanged;
  const _VhsStandeeToggle({
    required this.standeeMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, bool active, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: kSp3, vertical: kSp1),
          decoration: BoxDecoration(
            color: active ? kColorCyan : kColorPanel,
            border: Border.all(color: active ? kColorCyan : kColorBorder),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              color: active ? kColorTextInv : kColorText2,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'PREVIEW:',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: kFsMeta,
            color: kColorText3,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: kSp2),
        btn('VHS Tape', !standeeMode, () => onChanged(false)),
        btn('Standee', standeeMode, () => onChanged(true)),
      ],
    );
  }
}

/// "🖼  Replace Image" button shown to the LEFT of the VHS/Standee toggle
/// in the NR preview header.  Port of `_vp_replace_btn`
/// (RR_VHS_Tool.py:7766-7771) — clicking opens the same OS file picker
/// the right-rail UPLOAD/REPLACE button uses, and `setImage` preserves
/// the existing offset/zoom (matches `_upload` at Z. 12651-12656).
class _NrReplaceImageButton extends ConsumerStatefulWidget {
  final String bkgTex;
  const _NrReplaceImageButton({required this.bkgTex});

  @override
  ConsumerState<_NrReplaceImageButton> createState() =>
      _NrReplaceImageButtonState();
}

class _NrReplaceImageButtonState
    extends ConsumerState<_NrReplaceImageButton> {
  bool _busy = false;
  bool _hover = false;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
        dialogTitle: 'Pick replacement image for ${widget.bkgTex}',
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

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _busy ? null : _pick,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: kSp3, vertical: kSp1),
          decoration: BoxDecoration(
            color: _hover ? kColorPanel : kColorBorder,
            border: Border.all(color: kColorBorder),
          ),
          child: Text(
            '🖼  Replace Image',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: kFsMeta,
              color: _busy ? kColorText3 : kColorText,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// _NrShapeSection / _NrShapeCard live in slot_options_panel.dart — the
// picker belongs in the right-rail form column (matches Python's layout,
// RR_VHS_Tool.py:8735-8776).  Removed from here to keep the preview
// column focused on cover + cropper + zone labels.

/// Click-to-upload placeholder shown when the slot has no image yet.
/// Single-click opens a file picker — same code path as the right-rail
/// UPLOAD button.
class _UploadPicker extends ConsumerStatefulWidget {
  final String bkgTex;
  const _UploadPicker({required this.bkgTex});

  @override
  ConsumerState<_UploadPicker> createState() => _UploadPickerState();
}

class _UploadPickerState extends ConsumerState<_UploadPicker> {
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

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _busy ? null : _pick,
        child: Container(
          decoration: BoxDecoration(
            color: kColorPanel,
            border: Border.all(color: kColorBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: const _PreviewPlaceholder(
            label: 'CLICK TO UPLOAD',
            sublabel: 'PNG · JPG · WEBP · BMP',
            icon: Icons.upload_file_outlined,
            accent: kColorPink,
          ),
        ),
      ),
    );
  }
}

/// Cover preview + editor controls + status, sharing transient state so
/// the slider/buttons can drive a live preview without a per-tick disk write.
///
/// State held here:
///   * `_ovX` / `_ovY` / `_ovZoom` — transient overrides while the slider is
///     being dragged.  Cleared on commit.
///   * `_imageGen` — bumped after `↻ Rotate` rewrites the file in place, so
///     the underlying `Image.file` is rebuilt against the new bytes instead
///     of the cached pre-rotation pixels.
class _CoverEditorBlock extends ConsumerStatefulWidget {
  final String bkgTex;
  final int layout;
  final TextureReplacement replacement;
  /// When true: layout-aware overlay is forced off and "fit visible"
  /// resolves to fit-full-canvas (offset 0/0, zoom 1.0).  T_New_*
  /// textures don't sit on a VHS that can hide parts of the cover, so
  /// the layout overlay would just be misleading.
  final bool isNewRelease;
  /// Standee shape A/B/C — required when [isNewRelease] is true to drive
  /// the zone-line / shape-overlay drawing on the cropper.
  final String? nrShape;
  /// True = draw shape-specific overlay (arch/folds/corners) on top of
  /// the zone lines; false = zone lines only.
  final bool standeeMode;

  const _CoverEditorBlock({
    super.key,
    required this.bkgTex,
    required this.layout,
    required this.replacement,
    this.isNewRelease = false,
    this.nrShape,
    this.standeeMode = false,
  });

  @override
  ConsumerState<_CoverEditorBlock> createState() => _CoverEditorBlockState();
}

class _CoverEditorBlockState extends ConsumerState<_CoverEditorBlock> {
  int? _ovX;
  int? _ovY;
  double? _ovZoom;
  bool _rotating = false;
  bool _fitting = false;

  int get _x => _ovX ?? widget.replacement.offsetX;
  int get _y => _ovY ?? widget.replacement.offsetY;
  double get _zoom => _ovZoom ?? widget.replacement.zoom;

  @override
  void didUpdateWidget(covariant _CoverEditorBlock old) {
    super.didUpdateWidget(old);
    // When the saved values change (e.g. after a setTransform commit) drop
    // any leftover overrides so the UI reflects what's on disk.
    final r = widget.replacement;
    final or = old.replacement;
    if (r.offsetX != or.offsetX ||
        r.offsetY != or.offsetY ||
        r.zoom != or.zoom) {
      _ovX = null;
      _ovY = null;
      _ovZoom = null;
    }
  }

  Future<void> _commitTransform({
    required int offsetX,
    required int offsetY,
    required double zoom,
  }) async {
    await ref.read(replacementsControllerProvider).setTransform(
          widget.bkgTex,
          offsetX: offsetX,
          offsetY: offsetY,
          zoom: zoom,
        );
  }

  void _onCropperPreview(int x, int y, double z) {
    setState(() {
      _ovX = x;
      _ovY = y;
      _ovZoom = z;
    });
  }

  // Don't clear overrides eagerly — the cropper would briefly fall back to
  // `repl.offsetX/Y/zoom` (the pre-commit values) during the async disk
  // write, flashing the cover back to its old position.  didUpdateWidget
  // clears them once the new replacement lands.
  Future<void> _onCropperCommit(int x, int y, double z) async {
    setState(() {
      _ovX = x;
      _ovY = y;
      _ovZoom = z;
    });
    await _commitTransform(offsetX: x, offsetY: y, zoom: z);
  }

  void _onZoomPreview(double z) {
    setState(() => _ovZoom = z);
  }

  Future<void> _onZoomCommit(double z) async {
    setState(() => _ovZoom = z);
    await _commitTransform(offsetX: _x, offsetY: _y, zoom: z);
  }

  Future<void> _rotate() async {
    if (_rotating) return;
    final file = File(widget.replacement.path);
    if (!file.existsSync()) {
      _showError('Image file is missing — re-upload to enable rotate.');
      return;
    }
    setState(() => _rotating = true);
    try {
      await rotateCoverImageCw(file.path);
      // `Image.file(..., cacheWidth: …)` wraps the FileImage in a
      // ResizeImage with its own cache key, so FileImage.evict() alone
      // wouldn't catch the variants the cropper and the thumbnails use
      // (different cacheWidths).  Clearing the whole image cache is the
      // simple correct thing — rotate is rare.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      if (!mounted) return;
      // Bump the global generation: forces every Image.file key to remount
      // and re-invalidates imageDimensionsProvider so the swapped (h, w)
      // dims get picked up.
      ref
          .read(coverImageGenerationProvider(file.path).notifier)
          .state += 1;
      // Auto-Fit-Visible against the new orientation: a portrait→landscape
      // rotate at the old transform would otherwise show a tall slice of
      // the new wide image, which is what users hit as "rotation looks
      // wrong" before this got wired up.
      final dims =
          await ref.read(imageDimensionsProvider(file.path).future);
      if (!mounted) return;
      if (dims != null) {
        final t = computeFitVisibleTransform(
          imageWidth: dims.w,
          imageHeight: dims.h,
          layout: widget.layout,
        );
        if (t != null) {
          await _commitTransform(
            offsetX: t.offsetX,
            offsetY: t.offsetY,
            zoom: t.zoom,
          );
        }
      }
      if (mounted) setState(() => _rotating = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _rotating = false);
      _showError('Rotate failed: $e');
    }
  }

  Future<void> _fillCanvas() async {
    await _commitTransform(
      offsetX: kFillCanvasTransform.offsetX,
      offsetY: kFillCanvasTransform.offsetY,
      zoom: kFillCanvasTransform.zoom,
    );
  }

  Future<void> _fitVisible() async {
    if (_fitting) return;
    setState(() => _fitting = true);
    try {
      // For NRs the entire canvas IS visible, so "fit visible" reduces
      // to the fill-canvas transform — no per-image dimensions lookup.
      if (widget.isNewRelease) {
        await _commitTransform(
          offsetX: kFillCanvasTransform.offsetX,
          offsetY: kFillCanvasTransform.offsetY,
          zoom: kFillCanvasTransform.zoom,
        );
        return;
      }
      final dims = await ref
          .read(imageDimensionsProvider(widget.replacement.path).future);
      if (dims == null) {
        if (mounted) _showError('Could not read image dimensions.');
        return;
      }
      final t = computeFitVisibleTransform(
        imageWidth: dims.w,
        imageHeight: dims.h,
        layout: widget.layout,
      );
      if (t == null) return;
      await _commitTransform(
        offsetX: t.offsetX,
        offsetY: t.offsetY,
        zoom: t.zoom,
      );
    } finally {
      if (mounted) setState(() => _fitting = false);
    }
  }

  void _showError(String msg) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final repl = widget.replacement;
    final imageGen = ref.watch(coverImageGenerationProvider(repl.path));
    final dimsAsync = ref.watch(imageDimensionsProvider(repl.path));
    final snapOn = ref.watch(snapEnabledProvider);
    // T_New textures cover the full 1024×2048 with no VHS framing, so the
    // layout-aware overlay (red-hatched zones, cyan visible-area border)
    // doesn't apply.  Force it off for NR slots — even when the user has
    // overlay enabled globally for genre slots.
    final overlayOn =
        widget.isNewRelease ? false : ref.watch(layoutOverlayProvider);
    final frameDeco = BoxDecoration(
      color: kColorPanel,
      border: Border.all(color: kColorBorder),
    );

    Widget cropperOrPlaceholder() {
      return dimsAsync.when(
        loading: () => const _PreviewPlaceholder(
          label: 'LOADING…',
          sublabel: 'reading image dimensions',
          icon: Icons.hourglass_empty,
        ),
        error: (e, _) => _PreviewPlaceholder(
          label: 'DECODE ERROR',
          sublabel: '$e',
          isError: true,
        ),
        data: (dims) {
          if (dims == null) {
            return _PreviewPlaceholder(
              label: 'IMAGE MISSING',
              sublabel: repl.path,
              isError: true,
            );
          }
          return CroppingPreview(
            file: File(repl.path),
            savedOffsetX: _x,
            savedOffsetY: _y,
            savedZoom: _zoom,
            layout: widget.layout,
            imageWidth: dims.w,
            imageHeight: dims.h,
            imageGeneration: imageGen,
            snapEnabled: snapOn,
            showOverlay: overlayOn,
            nrShape: widget.isNewRelease ? widget.nrShape : null,
            standeeMode: widget.standeeMode,
            onPreview: _onCropperPreview,
            onCommit: _onCropperCommit,
            onMissing: (_) => _PreviewPlaceholder(
              label: 'IMAGE MISSING',
              sublabel: repl.path,
              isError: true,
            ),
          );
        },
      );
    }

    final coverArea = Center(
      child: AspectRatio(
        aspectRatio: 1024 / 2048,
        child: Container(
          decoration: frameDeco,
          clipBehavior: Clip.antiAlias,
          child: cropperOrPlaceholder(),
        ),
      ),
    );

    // For NRs: paint zone-name labels in the gutters around the cover
    // (Python's `_label_x = max(2, _real_dx - 6)` block at
    // RR_VHS_Tool.py:12030-12084).  The painter sits in a Positioned.fill
    // sibling so it can draw outside the cover's `clipBehavior`.
    final coverWithLabels = (widget.isNewRelease && widget.nrShape != null)
        ? Stack(
            fit: StackFit.expand,
            children: [
              coverArea,
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: NrZoneLabelsPainter(
                      shape: widget.nrShape!,
                      standeeMode: widget.standeeMode,
                    ),
                  ),
                ),
              ),
            ],
          )
        : coverArea;

    final fileName = p.basename(repl.path);
    final infoText = dimsAsync.maybeWhen(
      data: (dims) => dims != null
          ? '$fileName  —  ${dims.w} × ${dims.h} px'
          : fileName,
      orElse: () => fileName,
    );
    final quality = dimsAsync.maybeWhen(
      data: (dims) => dims == null
          ? CoverQualityAssessment.ok
          : assessCoverQuality(
              imageWidth: dims.w,
              imageHeight: dims.h,
              zoom: _zoom,
              offsetX: _x,
              offsetY: _y,
            ),
      orElse: () => CoverQualityAssessment.ok,
    );

    return Column(
      children: [
        Expanded(child: coverWithLabels),
        const SizedBox(height: kSp1),
        // Filename + resolution under the cover, plus the quality-warning
        // chip (briefing §6.3 + §10.2 — small chip near the canvas when
        // the image is upscaled or barely covering the canvas).  Port of
        // Python's `_info_var` row (RR_VHS_Tool.py:7954-7959, 11657-11675).
        Row(
          children: [
            Expanded(
              child: Text(
                infoText,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: kFsMeta,
                  color: kColorText3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (quality.level != CoverQualityLevel.ok) ...[
              const SizedBox(width: kSp2),
              CoverQualityChip(assessment: quality),
            ],
          ],
        ),
        const SizedBox(height: kSp1),
        CropEditorBar(
          zoom: _zoom,
          enabled: true,
          onZoomPreview: _onZoomPreview,
          onZoomCommit: _onZoomCommit,
          onRotate: _rotating ? null : _rotate,
          onFillCanvas: _fillCanvas,
          onFitVisible: _fitting ? null : _fitVisible,
        ),
        const SizedBox(height: kSp1),
        _CropperStatus(
          bkgTex: widget.bkgTex,
          offsetX: _x,
          offsetY: _y,
          zoom: _zoom,
        ),
      ],
    );
  }
}

/// Status strip under the cover: live offset/zoom readout + Reset link.
/// Mirrors Python's `zoom_label` + `_reset_transform` (RR_VHS_Tool.py:11502
/// and 11515-11530).
class _CropperStatus extends ConsumerStatefulWidget {
  final String bkgTex;
  final int offsetX;
  final int offsetY;
  final double zoom;

  const _CropperStatus({
    required this.bkgTex,
    required this.offsetX,
    required this.offsetY,
    required this.zoom,
  });

  @override
  ConsumerState<_CropperStatus> createState() => _CropperStatusState();
}

class _CropperStatusState extends ConsumerState<_CropperStatus> {
  bool _resetHover = false;

  bool get _isDefault =>
      widget.offsetX == 0 && widget.offsetY == 0 && widget.zoom == 1.0;

  Future<void> _reset() async {
    await ref.read(replacementsControllerProvider).setTransform(
          widget.bkgTex,
          offsetX: 0,
          offsetY: 0,
          zoom: 1.0,
        );
  }

  @override
  Widget build(BuildContext context) {
    final readout =
        'offset ${widget.offsetX}, ${widget.offsetY}  ·  zoom ${widget.zoom.toStringAsFixed(2)}x';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          readout,
          style: const TextStyle(fontSize: kFsMeta, color: kColorText3),
        ),
        if (!_isDefault) ...[
          const SizedBox(width: kSp2),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _resetHover = true),
            onExit: (_) => setState(() => _resetHover = false),
            child: GestureDetector(
              onTap: _reset,
              child: Text(
                'reset',
                style: TextStyle(
                  fontSize: kFsMeta,
                  color: _resetHover ? kColorPink : kColorText2,
                  decoration:
                      _resetHover ? TextDecoration.underline : null,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool isError;
  final IconData? icon;
  final Color? accent;

  const _PreviewPlaceholder({
    required this.label,
    required this.sublabel,
    this.isError = false,
    this.icon,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final fg = accent ?? (isError ? kColorPink : kColorText3);
    return Container(
      color: kColorBg,
      padding: const EdgeInsets.all(kSp4),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon ??
                (isError
                    ? Icons.broken_image_outlined
                    : Icons.image_not_supported_outlined),
            color: fg,
            size: 64,
          ),
          const SizedBox(height: kSp2),
          Text(
            label,
            style: TextStyle(
              fontSize: kFsBody,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: kSp1),
          Text(
            sublabel,
            style: TextStyle(fontSize: kFsMeta, color: fg),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: const Padding(
          padding: EdgeInsets.all(kSp4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.movie_outlined, color: kColorText3, size: 56),
              SizedBox(height: kSp2),
              Text(
                'SELECT A SLOT',
                style: TextStyle(
                  fontSize: kFsBody,
                  fontWeight: FontWeight.w700,
                  color: kColorText3,
                  letterSpacing: 1.5,
                ),
              ),
              SizedBox(height: kSp1),
              Text(
                'Pick a card from the shelf on the left to see its full cover here.',
                textAlign: TextAlign.center,
                style: TextStyle(
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
