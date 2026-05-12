import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/constants/genres.dart';

/// Pure result of `computeFitVisibleTransform` / `computeFillCanvasTransform`.
/// The caller persists these via `ReplacementsController.setTransform`.
class CoverTransform {
  final int offsetX;
  final int offsetY;
  final double zoom;
  const CoverTransform({
    required this.offsetX,
    required this.offsetY,
    required this.zoom,
  });
}

/// Rotate the image file at [path] 90° clockwise *in place*.  Port of
/// Python's `_rotate_image` (RR_VHS_Tool.py:10021-10043) — it overwrites the
/// user's file so the next `prepare_image` pass sees the new orientation.
///
/// Throws [FormatException] when the file can't be decoded or re-encoded.
/// The output format is inferred from the file's extension (PNG → encodePng,
/// JPG → encodeJpg, …) via [img.encodeNamedImage].
Future<void> rotateCoverImageCw(String path) async {
  final image = await img.decodeImageFile(path);
  if (image == null) {
    throw FormatException('Could not decode image at $path');
  }
  final rotated = img.copyRotate(image, angle: 90);
  final encoded = img.encodeNamedImage(path, rotated);
  if (encoded == null) {
    throw FormatException('Unsupported image format for $path');
  }
  await File(path).writeAsBytes(encoded);
}

/// Read the pixel dimensions of an image file via header-only decode —
/// never touches the pixel buffer.  Returns null if the file is missing,
/// truncated, or in an unsupported format.
///
/// Performance: shelf thumbnails read dims for every visible card on
/// every tab switch.  The naive `decodeImage(bytes)` path did a full
/// RGB decode of multi-megabyte covers (≈500 ms per file on typical
/// 4 K source images), which serialized into the 1 s freeze the user
/// reported on tab switch.  This version:
///
///   * reads at most the first 64 KB of the file — enough for the
///     header of every format `package:image` supports (PNG IHDR is
///     in the first 24 bytes, JPEG SOF0 is in the first few KB),
///   * calls `findDecoderForData` + `startDecode` which read width /
///     height from the header without producing a pixel buffer.
///
/// Falls back to the full file (still header-only decode) when the
/// chunked path returns null — a defensive belt-and-braces for
/// unusual formats whose headers straddle the 64 KB boundary.
Future<({int width, int height})?> readImageDimensions(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;

  Future<({int width, int height})?> tryDecode(Uint8List bytes) async {
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final info = decoder.startDecode(bytes);
    if (info == null) return null;
    return (width: info.width, height: info.height);
  }

  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final len = await raf.length();
    final chunkLen = len < 65536 ? len : 65536;
    final chunk = await raf.read(chunkLen);
    final fromChunk = await tryDecode(chunk);
    if (fromChunk != null) return fromChunk;
    if (chunkLen >= len) return null; // already read the whole file
  } finally {
    await raf?.close();
  }
  // Fallback: full-file header probe.  Still header-only decode, just
  // covering the rare case where the header sits past 64 KB.
  final bytes = await file.readAsBytes();
  return tryDecode(bytes);
}

/// Layout-aware "Fit Visible": scale the image so it covers the selected
/// layout's visible (cyan) area in both dimensions, then centre it
/// horizontally on the visible area's x-centre and align its top with the
/// window top.
///
/// Adapted from `_fit_to_canvas` (RR_VHS_Tool.py:11550-11622).  Diverges from
/// Python on one point: the Python tool only matches the image's *height*
/// to the visible window (`safe_h / ih`), which leaves narrow images with
/// black bars on the sides — visually a "contain" fit.  The Flutter port
/// uses `max(safe_w/iw, safe_h/ih)` so the visible area is always fully
/// covered (any overflow is cropped, matching every modern crop UI's
/// "fill" affordance).  For typical 2:3 posters the two formulas agree.
///
/// Returns null when [imageWidth] or [imageHeight] is zero.  Out-of-range
/// layouts collapse to layout 1, mirroring Python's fallback chain
/// (saved → preview overlay → 1).
CoverTransform? computeFitVisibleTransform({
  required int imageWidth,
  required int imageHeight,
  required int layout,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) return null;

  var n = layout;
  if (n < 1 || n > 5) n = 1;

  // Safe area = the cyan visible window, sourced from layoutVisibleRect()
  // and rounded to integer pixels.  Pythons `_fit_to_canvas` used the
  // global HIDDEN_LEFT/RIGHT bands instead, but those are 3 (layout 1) to
  // 30 (layout 4) pixels off from where the cyan border actually sits,
  // which left a visible gap inside the safe area after Fit Visible.
  final r = layoutVisibleRect(n)!;
  final visTop = r.top.round();
  final visBot = r.bottom.round();
  final visLeft = r.left.round();
  final visRight = r.right.round();
  final safeH = visBot - visTop;
  final safeW = visRight - visLeft;
  final safeCx = visLeft + _pyFloorDiv(safeW, 2);

  final scaleW = kTextureBkgWidth / imageWidth;
  final scaleH = kTextureBkgHeight / imageHeight;
  final baseScale = scaleW > scaleH ? scaleW : scaleH;
  // Cover-fit on the visible window — the larger of (window-width /
  // image-width) and (window-height / image-height) so neither dimension
  // leaves a gap.
  final fitScaleW = safeW / imageWidth;
  final fitScaleH = safeH / imageHeight;
  final fitScale = fitScaleW > fitScaleH ? fitScaleW : fitScaleH;
  final zoom = (fitScale / baseScale * 1000).ceil() / 1000.0;

  final actualScale = baseScale * zoom;
  // Python's `int(...)` truncates toward zero — same as Dart's `.toInt()`.
  final imgWTex = (imageWidth * actualScale).toInt();
  final imgHTex = (imageHeight * actualScale).toInt();
  // Use Python-style floor division: when (TEX - img) goes negative because
  // the zoomed image overflows the canvas, `~/` truncates toward zero while
  // Python's `//` floors toward -inf.  These two diverge by 1 on odd negative
  // numerators, which would otherwise drift offsets by a pixel.
  final imgDefaultX = _pyFloorDiv(kTextureBkgWidth - imgWTex, 2);
  final imgDefaultY = _pyFloorDiv(kTextureBkgHeight - imgHTex, 2);

  final offsetX = safeCx - _pyFloorDiv(imgWTex, 2) - imgDefaultX;
  final offsetY = visTop - imgDefaultY;

  return CoverTransform(offsetX: offsetX, offsetY: offsetY, zoom: zoom);
}

/// Python-style floor division (`//`) — diverges from Dart's `~/` on negative
/// numerators (Python floors toward -∞, Dart truncates toward 0).
int _pyFloorDiv(int a, int b) => (a / b).floor();

/// "Fill Canvas": cover the full 1024×2048 canvas with no layout-aware
/// cropping (matches NR / standee positioning).  Pure port of
/// `_fit_full_canvas` (RR_VHS_Tool.py:11532-11548).
const CoverTransform kFillCanvasTransform = CoverTransform(
  offsetX: 0,
  offsetY: 0,
  zoom: 1.0,
);

/// Result of `applyDragSnap` — the snapped offset plus flags telling the
/// renderer whether to draw the cyan dashed centre-axis guide lines.
class SnappedOffset {
  final int offsetX;
  final int offsetY;

  /// True when the X-snap landed on the visible-area centre target (only
  /// then does Pythons preview draw a vertical guide line).  Edge snaps
  /// (cyan-left/right or canvas edges) don't draw guides.
  final bool centerSnapX;

  /// True when the Y-snap landed on the visible-area centre target.
  final bool centerSnapY;

  const SnappedOffset({
    required this.offsetX,
    required this.offsetY,
    required this.centerSnapX,
    required this.centerSnapY,
  });
}

/// Apply drag-time snapping to a raw (offset_x, offset_y) candidate.
/// Pure port of `RR_VHS_Tool.py:11199-11267` for the genre / VHS case
/// (NR Standee mode is deferred to slice 5).
///
/// 5 X-targets and 5 Y-targets, all measured against the image's edges
/// after centring on the canvas: safe-area centre, safe-area left/right,
/// canvas left/right (and the Y analogues).  We pick the nearest target
/// within [snapRadius] (default 40 canvas-pixels), independently per
/// axis.  When no target is within range, the raw offset passes through.
SnappedOffset applyDragSnap({
  required int rawOffsetX,
  required int rawOffsetY,
  required int imageWidth,
  required int imageHeight,
  required double zoom,
  required int layout,
  int snapRadius = 40,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) {
    return SnappedOffset(
      offsetX: rawOffsetX,
      offsetY: rawOffsetY,
      centerSnapX: false,
      centerSnapY: false,
    );
  }

  // Image dimensions in canvas-coords after cover-fit + zoom (matches
  // _render_preview's `nw`/`nh`).
  final scaleW = kTextureBkgWidth / imageWidth;
  final scaleH = kTextureBkgHeight / imageHeight;
  final actualScale = (scaleW > scaleH ? scaleW : scaleH) * zoom;
  final imgWTex = (imageWidth * actualScale).toInt();
  final imgHTex = (imageHeight * actualScale).toInt();
  final imgDefaultX = _pyFloorDiv(kTextureBkgWidth - imgWTex, 2);
  final imgDefaultY = _pyFloorDiv(kTextureBkgHeight - imgHTex, 2);

  // Visible / cyan area edges (rounded to int — same source the cyan
  // border painter uses, so snap targets line up with what the user sees).
  final r = layoutVisibleRect(
    layout < 1 || layout > 5 ? 1 : layout,
  );
  final int svTop, svBot, svLeft, svRight;
  if (r != null) {
    svTop = r.top.round();
    svBot = r.bottom.round();
    svLeft = r.left.round();
    svRight = r.right.round();
  } else {
    svTop = kHiddenTop;
    svBot = kTextureBkgHeight - kHiddenBottom;
    svLeft = kHiddenLeft;
    svRight = kTextureBkgWidth - kHiddenRight;
  }
  final safeCx = ((svLeft + svRight) / 2).floor(); // Pythons int(...)
  final safeCy = ((svTop + svBot) / 2).floor();

  // (target_offset_value, is_center).  Order matches Python's list so
  // ties go to the same winner.
  final xTargets = <(int, bool)>[
    (safeCx - _pyFloorDiv(imgWTex, 2) - imgDefaultX, true),
    (svLeft - imgDefaultX, false),
    (svRight - imgWTex - imgDefaultX, false),
    (-imgDefaultX, false),
    ((kTextureBkgWidth - imgWTex) - imgDefaultX, false),
  ];
  final yTargets = <(int, bool)>[
    (safeCy - _pyFloorDiv(imgHTex, 2) - imgDefaultY, true),
    (svTop - imgDefaultY, false),
    (svBot - imgHTex - imgDefaultY, false),
    (-imgDefaultY, false),
    ((kTextureBkgHeight - imgHTex) - imgDefaultY, false),
  ];

  int? bestX;
  bool bestXIsCenter = false;
  int bestXDist = snapRadius;
  for (final (val, isCenter) in xTargets) {
    final d = (rawOffsetX - val).abs();
    if (d < bestXDist) {
      bestX = val;
      bestXIsCenter = isCenter;
      bestXDist = d;
    }
  }
  int? bestY;
  bool bestYIsCenter = false;
  int bestYDist = snapRadius;
  for (final (val, isCenter) in yTargets) {
    final d = (rawOffsetY - val).abs();
    if (d < bestYDist) {
      bestY = val;
      bestYIsCenter = isCenter;
      bestYDist = d;
    }
  }

  return SnappedOffset(
    offsetX: bestX ?? rawOffsetX,
    offsetY: bestY ?? rawOffsetY,
    centerSnapX: bestX != null && bestXIsCenter,
    centerSnapY: bestY != null && bestYIsCenter,
  );
}
