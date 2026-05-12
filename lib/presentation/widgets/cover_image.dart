import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/genres.dart';
import '../../core/theme/app_theme.dart';

/// Renders a cover image inside a 1024×2048-aspect (or layout-visible-rect)
/// viewport using **Python's `_render_preview` math verbatim**:
///
///   base    = max(TEX_W / iw, TEX_H / ih)         (cover-fit on canvas)
///   img.w   = iw * base * zoom        (in canvas-pixels)
///   img.h   = ih * base * zoom
///   img.x   = (TEX_W - img.w) // 2 + offset_x     (centered + shifted)
///   img.y   = (TEX_H - img.h) // 2 + offset_y
///
/// Then the canvas is mapped to the widget [size] (or to a sub-rect via
/// [viewport]) and the image is placed via a [Positioned] with explicit
/// `left/top/width/height`.  This is critical: the earlier
/// `Image.file(fit:cover)` + `Transform.scale(zoom)` shortcut is wrong at
/// `zoom < 1` — it shrinks the *whole widget*, leaving padding inside the
/// safe area when Fit Visible drops zoom below 1.
///
/// [imageWidth] / [imageHeight] must be the source image's natural pixel
/// dimensions (from `imageDimensionsProvider`).  When unknown, callers
/// should render a placeholder rather than guess — the math doesn't work
/// without them.
///
/// [viewport] selects which sub-rect of the 1024×2048 canvas fills the
/// widget.  Default is the full canvas (cropper).  The thumbnail passes
/// `layoutVisibleRect(layout)` so it shows only the cyan area at slot's
/// layout — i.e. "what the user will see in-game" rather than the whole
/// uncropped texture.
///
/// [imageGeneration] is mixed into the [Image.file] key so rotate-driven
/// bumps force a fresh decode against the rewritten file bytes.
Widget buildCoverImageStack({
  required File file,
  required int imageWidth,
  required int imageHeight,
  required int offsetX,
  required int offsetY,
  required double zoom,
  required int imageGeneration,
  required Size size,
  Rect? viewport,
  Widget? overlay,
  // 4× display width is right for the cropper (user can wheel-zoom up to
  // 4× in), but wasteful for thumbnails (no zoom possible — every extra
  // multiplier costs that-squared in decode time and pixel memory).
  // Callers that don't need zoom-headroom should pass 1.5.
  double cacheWidthMultiplier = 4.0,
  /// When true, paint a small spinner centred over the canvas until
  /// the first frame of the file has been decoded.  Thumbnails enable
  /// this; the cropper leaves it off because its parent already shows
  /// a "LOADING" placeholder while dimensions are read and the image
  /// area would otherwise flash a spinner for a few milliseconds on
  /// every selection change.
  bool showDecodeProgress = false,
}) {
  final v = viewport ??
      Rect.fromLTWH(
        0,
        0,
        kTextureBkgWidth.toDouble(),
        kTextureBkgHeight.toDouble(),
      );
  // Display-pixels per canvas-pixel.  Assumes the widget's aspect matches
  // the viewport's — the caller is responsible for that via AspectRatio.
  final scale = size.width / v.width;

  // Pythons math (RR_VHS_Tool.py:11824-11857).
  final scaleW = kTextureBkgWidth / imageWidth;
  final scaleH = kTextureBkgHeight / imageHeight;
  final baseScale = scaleW > scaleH ? scaleW : scaleH;
  final actualScale = baseScale * zoom;
  final imgCanvasW = imageWidth * actualScale;
  final imgCanvasH = imageHeight * actualScale;
  final imgCanvasX = (kTextureBkgWidth - imgCanvasW) / 2 + offsetX;
  final imgCanvasY = (kTextureBkgHeight - imgCanvasH) / 2 + offsetY;

  // Map canvas-coords to widget-coords (subtract viewport origin).
  final dispLeft = (imgCanvasX - v.left) * scale;
  final dispTop = (imgCanvasY - v.top) * scale;
  final dispW = imgCanvasW * scale;
  final dispH = imgCanvasH * scale;

  final image = Image.file(
    file,
    key: ValueKey('${file.path}|$imageGeneration'),
    fit: BoxFit.fill,
    cacheWidth:
        (size.width * cacheWidthMultiplier).clamp(256, 4096).round(),
    // Default Flutter frame builder already fades the first frame in
    // gradually (`gaplessPlayback`-style).  We wrap it only when the
    // caller asked for an explicit progress indicator on top.
    frameBuilder: showDecodeProgress
        ? (context, child, frame, wasSync) {
            // `wasSync == true` means the image was already in cache and
            // painted synchronously — no indicator needed.  Otherwise
            // show the indicator until the first frame lands.
            if (wasSync || frame != null) return child;
            return Stack(
              fit: StackFit.expand,
              children: [
                child, // first paint goes through this slot
                const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(kColorText3),
                    ),
                  ),
                ),
              ],
            );
          }
        : null,
  );

  return ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        Container(color: kColorBg),
        Positioned(
          left: dispLeft,
          top: dispTop,
          width: dispW,
          height: dispH,
          child: image,
        ),
        // Caller-owned overlay layer.  We don't wrap it in IgnorePointer
        // so callers can mix interactive widgets (e.g. the cropper's "?"
        // help button) with the painter-only safe-area overlay.  Painter-
        // only overlays should wrap themselves in IgnorePointer.
        ?overlay,
      ],
    ),
  );
}

/// Visible rect in canvas-coords for a given layout, with edges rounded to
/// integers so int-math elsewhere (Fit Visible, viewport mapping) stays
/// pixel-stable.  Falls back to the global hidden-band defaults when the
/// layout is out of range (random / 0 / >5).
Rect layoutVisibleRectInt(int layout) {
  final r = layoutVisibleRect(layout);
  if (r != null) {
    return Rect.fromLTRB(
      r.left.roundToDouble(),
      r.top.roundToDouble(),
      r.right.roundToDouble(),
      r.bottom.roundToDouble(),
    );
  }
  return Rect.fromLTRB(
    kHiddenLeft.toDouble(),
    kHiddenTop.toDouble(),
    (kTextureBkgWidth - kHiddenRight).toDouble(),
    (kTextureBkgHeight - kHiddenBottom).toDouble(),
  );
}
