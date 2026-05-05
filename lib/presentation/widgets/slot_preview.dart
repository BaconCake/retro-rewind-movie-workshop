import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../data/services/cover_actions.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';
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
      return const _EmptyState();
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
      return const _EmptyState();
    }

    final repl = replacements[slot.bkgTex];

    return Padding(
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

  const _CoverEditorBlock({
    super.key,
    required this.bkgTex,
    required this.layout,
    required this.replacement,
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
    final overlayOn = ref.watch(layoutOverlayProvider);
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

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1024 / 2048,
              child: Container(
                decoration: frameDeco,
                clipBehavior: Clip.antiAlias,
                child: cropperOrPlaceholder(),
              ),
            ),
          ),
        ),
        const SizedBox(height: kSp2),
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
