import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/datatable/slot_data.dart';
import '../providers/providers.dart';

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
                  imagePath: repl?.path,
                ),
              ),
            ),
          ),
          const SizedBox(height: kSp3),
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

/// Wraps the cover image in a clickable frame: clicking the frame opens
/// a file picker and writes the chosen image to `replacements.json`.
/// This is the same path the right-rail "UPLOAD"/"REPLACE" button uses,
/// so users can act from either column.
class _PreviewFrame extends ConsumerStatefulWidget {
  final String bkgTex;
  final String? imagePath;

  const _PreviewFrame({required this.bkgTex, this.imagePath});

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
          child: _PreviewImage(path: widget.imagePath),
        ),
      ),
    );
  }
}

class _PreviewImage extends StatelessWidget {
  final String? path;

  const _PreviewImage({this.path});

  @override
  Widget build(BuildContext context) {
    final p = path;
    if (p == null) {
      return const _PreviewPlaceholder(
        label: 'CLICK TO UPLOAD',
        sublabel: 'PNG · JPG · WEBP · BMP',
        icon: Icons.upload_file_outlined,
        accent: kColorPink,
      );
    }
    final file = File(p);
    if (!file.existsSync()) {
      return _PreviewPlaceholder(
        label: 'IMAGE MISSING',
        sublabel: p,
        isError: true,
      );
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => _PreviewPlaceholder(
        label: 'DECODE ERROR',
        sublabel: p,
        isError: true,
      ),
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
