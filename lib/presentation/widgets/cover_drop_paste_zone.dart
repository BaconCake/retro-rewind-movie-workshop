import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pasteboard/pasteboard.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/entities/new_release_slot.dart';
import '../providers/providers.dart';

/// Wraps a preview pane with file drag-drop support.
///
/// Ctrl+V handling lives at the home-page level (see `home_page.dart`'s
/// `Shortcuts` block) — keyboard shortcuts only fire when the focused
/// widget is inside their `Shortcuts` ancestor, and a per-pane Focus
/// fights with text-field focus elsewhere in the UI.  Centralising at
/// home_page means Ctrl+V works regardless of which widget has focus
/// (and falls through to text fields when a TextField is active).
///
/// [bkgTex] is the texture key for the slot that should receive the
/// upload.  When null, the zone is inert — drag is ignored.  This lets
/// callers wrap their content unconditionally.
class CoverDropPasteZone extends ConsumerStatefulWidget {
  final String? bkgTex;
  final Widget child;

  const CoverDropPasteZone({
    super.key,
    required this.bkgTex,
    required this.child,
  });

  @override
  ConsumerState<CoverDropPasteZone> createState() =>
      _CoverDropPasteZoneState();
}

const Set<String> kCoverImageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
};

/// Paste an image from the system clipboard onto the currently-selected
/// slot.  Called from the home-page Ctrl+V shortcut.
///
/// Behaviour:
///   * If a TextField has primary focus, returns immediately so Ctrl+V
///     pastes text into the field as normal.
///   * Otherwise looks up the active slot via [selectedSlotBkgProvider]
///     and resolves to bkgTex (NR slots through their SKU, genre slots
///     directly).
///   * Reads bytes from the clipboard via [Pasteboard.image].  Returns
///     a no-op message when no image is available — the user may have
///     copied a file from Explorer (CF_HDROP, not CF_DIB), in which
///     case drag-drop is the right path.
///   * Saves bytes to `<workingDir>/.pasted_covers/<bkgTex>_<ms>.png`
///     and calls [ReplacementsController.setImage].
///
/// All user-visible feedback goes through [ScaffoldMessenger] so the
/// shortcut never silently swallows a paste attempt.
Future<void> pasteClipboardImageToActiveSlot(
  WidgetRef ref,
  BuildContext context,
) async {
  // Skip if a text input has focus — let it handle Ctrl+V natively.
  final primary = FocusManager.instance.primaryFocus;
  if (primary != null) {
    final widget = primary.context?.widget;
    if (widget is EditableText) return;
    if (widget?.runtimeType.toString().contains('Editable') ?? false) {
      return;
    }
  }

  final selected = ref.read(selectedSlotBkgProvider);
  if (selected == null) {
    _flashSnack(context, 'Select a slot first to paste into.');
    return;
  }

  // Resolve the current bkgTex for the selection.  Genre slots use the
  // selection key directly; NR slots key by `nr:<sku>` and need a
  // lookup so we know which texture name to write the replacement under.
  String? bkgTex;
  if (selected.startsWith(kNrSelectionPrefix)) {
    final sku =
        int.tryParse(selected.substring(kNrSelectionPrefix.length));
    if (sku == null) return;
    final nrs = await ref.read(nrSlotsProvider.future);
    for (final NewReleaseSlot n in nrs) {
      if (n.sku == sku) {
        bkgTex = n.bkgTex;
        break;
      }
    }
  } else {
    bkgTex = selected;
  }
  if (bkgTex == null) return;

  // Two clipboard shapes:
  //   * Image bytes (CF_DIB on Windows) — screenshots, web "copy image".
  //     Saved to a per-paste file in `<workingDir>/.pasted_covers/`.
  //   * File path list (CF_HDROP on Windows) — Ctrl+C on a file in
  //     Explorer.  No save needed; we set the replacement to that path
  //     directly, same shape as the drag-drop case.
  Uint8List? bytes;
  try {
    bytes = await Pasteboard.image;
  } catch (e) {
    if (context.mounted) _flashSnack(context, 'Clipboard read failed: $e');
    return;
  }
  if (bytes != null && bytes.isNotEmpty) {
    final dir = ref.read(workingDirProvider);
    final pastedDir = Directory(p.join(dir, '.pasted_covers'));
    if (!await pastedDir.exists()) {
      await pastedDir.create(recursive: true);
    }
    final unixMs = DateTime.now().millisecondsSinceEpoch;
    final outPath = p.join(pastedDir.path, '${bkgTex}_$unixMs.png');
    await File(outPath).writeAsBytes(bytes);
    await ref.read(replacementsControllerProvider).setImage(bkgTex, outPath);
    if (context.mounted) _flashSnack(context, 'Cover pasted from clipboard.');
    return;
  }

  // No image bytes — try the file-path fallback.  Pasteboard.files
  // returns ["C:\\path\\to\\file.png"] when the user copied an image
  // file in Explorer (CF_HDROP).  Picks the first file whose extension
  // is in [kCoverImageExtensions].
  final List<String> files;
  try {
    files = await Pasteboard.files();
  } catch (_) {
    if (context.mounted) {
      _flashSnack(context,
          'No image in clipboard. Copy a screenshot or web image, or drag a file.');
    }
    return;
  }
  String? pickedFromExplorer;
  String? lastTriedExt;
  for (final fp in files) {
    final ext = p.extension(fp).toLowerCase();
    lastTriedExt = ext.isEmpty ? '(no extension)' : ext;
    if (kCoverImageExtensions.contains(ext)) {
      pickedFromExplorer = fp;
      break;
    }
  }
  if (pickedFromExplorer == null) {
    if (context.mounted) {
      _flashSnack(
          context,
          files.isEmpty
              ? 'No image in clipboard. Copy a screenshot or web image, or drag a file.'
              : 'Clipboard file is not an image ($lastTriedExt). '
                  'Accepted: .png .jpg .jpeg .webp .bmp');
    }
    return;
  }
  await ref
      .read(replacementsControllerProvider)
      .setImage(bkgTex, pickedFromExplorer);
  if (context.mounted) _flashSnack(context, 'Cover pasted from clipboard.');
}

void _flashSnack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 3),
  ));
}

class _CoverDropPasteZoneState extends ConsumerState<CoverDropPasteZone> {
  bool _hovering = false;

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _onDropDone(DropDoneDetails details) async {
    if (mounted) setState(() => _hovering = false);
    final bkg = widget.bkgTex;
    if (bkg == null) {
      _showSnack('Select a slot first to receive the dropped image.');
      return;
    }
    String? path;
    String? lastTriedExt;
    for (final f in details.files) {
      final ext = p.extension(f.path).toLowerCase();
      lastTriedExt = ext.isEmpty ? '(no extension)' : ext;
      if (kCoverImageExtensions.contains(ext)) {
        path = f.path;
        break;
      }
    }
    if (path == null) {
      _showSnack(details.files.isEmpty
          ? 'No file in drop.'
          : 'Not an image file ($lastTriedExt). '
              'Accepted: .png .jpg .jpeg .webp .bmp');
      return;
    }
    try {
      await ref
          .read(replacementsControllerProvider)
          .setImage(bkg, path);
      if (mounted) _showSnack('Cover updated.');
    } catch (e) {
      if (mounted) _showSnack('Upload failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.bkgTex != null;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) {
        if (!enabled) return;
        setState(() => _hovering = true);
      },
      onDragExited: (_) {
        setState(() => _hovering = false);
      },
      onDragDone: _onDropDone,
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: kColorPanel.withValues(alpha: 0.55),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: kSp4, vertical: kSp3),
                      decoration: BoxDecoration(
                        color: kColorPanel,
                        border: Border.all(color: kColorCyan, width: 2),
                      ),
                      child: const Text(
                        'DROP TO UPLOAD COVER',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: kFsBody,
                          color: kColorCyan,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
