import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../../domain/entities/texture_replacement.dart';
import '../providers/providers.dart';
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
            child: Center(
              child: AspectRatio(
                aspectRatio: 1024 / 2048,
                child: _PreviewFrame(
                  bkgTex: slot.bkgTex,
                  replacement: repl,
                ),
              ),
            ),
          ),
          if (repl != null) ...[
            const SizedBox(height: kSp1),
            _CropperStatus(bkgTex: slot.bkgTex, replacement: repl),
          ],
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
          LayoutStylePicker(
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

/// Cover-image frame.  Two distinct modes:
///
///   * **No image yet** — single-click opens a file picker (matches the
///     "click to upload" affordance from the read-only era).  This is the
///     same code path the right-rail UPLOAD button uses.
///
///   * **Image set** — frame becomes a [CroppingPreview]: drag to pan,
///     mouse-wheel to zoom.  Replacement now goes through the right-rail
///     REPLACE button only (matches Python — RR_VHS_Tool.py:11104+ uses
///     the canvas exclusively for cropping, never for re-pick).
class _PreviewFrame extends ConsumerStatefulWidget {
  final String bkgTex;
  final TextureReplacement? replacement;

  const _PreviewFrame({required this.bkgTex, this.replacement});

  @override
  ConsumerState<_PreviewFrame> createState() => _PreviewFrameState();
}

class _PreviewFrameState extends ConsumerState<_PreviewFrame> {
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
    final repl = widget.replacement;
    final frameDeco = BoxDecoration(
      color: kColorPanel,
      border: Border.all(color: kColorBorder),
    );

    if (repl == null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _busy ? null : _pick,
          child: Container(
            decoration: frameDeco,
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

    return Container(
      decoration: frameDeco,
      clipBehavior: Clip.antiAlias,
      child: CroppingPreview(
        file: File(repl.path),
        savedOffsetX: repl.offsetX,
        savedOffsetY: repl.offsetY,
        savedZoom: repl.zoom,
        onCommit: (x, y, z) =>
            ref.read(replacementsControllerProvider).setTransform(
                  widget.bkgTex,
                  offsetX: x,
                  offsetY: y,
                  zoom: z,
                ),
        onMissing: (_) => _PreviewPlaceholder(
          label: 'IMAGE MISSING',
          sublabel: repl.path,
          isError: true,
        ),
      ),
    );
  }
}

/// Status strip under the cover: live offset/zoom readout + Reset link.
/// Mirrors Python's `zoom_label` + `_reset_transform` (RR_VHS_Tool.py:11502
/// and 11515-11530).
class _CropperStatus extends ConsumerStatefulWidget {
  final String bkgTex;
  final TextureReplacement replacement;

  const _CropperStatus({required this.bkgTex, required this.replacement});

  @override
  ConsumerState<_CropperStatus> createState() => _CropperStatusState();
}

class _CropperStatusState extends ConsumerState<_CropperStatus> {
  bool _resetHover = false;

  bool get _isDefault =>
      widget.replacement.offsetX == 0 &&
      widget.replacement.offsetY == 0 &&
      widget.replacement.zoom == 1.0;

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
    final r = widget.replacement;
    final readout =
        'offset ${r.offsetX}, ${r.offsetY}  ·  zoom ${r.zoom.toStringAsFixed(2)}x';
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
