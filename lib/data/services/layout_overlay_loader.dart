import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:image/image.dart' as img;

import '../../domain/entities/app_config.dart';
import 'pak_cache.dart';

/// Loads `T_Layout_NN_bc_full.png` and applies the alpha-mask Python uses
/// for the in-canvas layout overlay: pixels whose brightest channel is
/// below 20 become fully transparent so the user's cover shows through
/// the "window".  Port of RR_VHS_Tool.py:12848-12857.
///
/// The PNG decode + 2048×2048 pixel sweep runs in an [Isolate.run] so
/// the UI thread stays responsive while the overlay loads.  Returns
/// `null` when the texture is unavailable (missing pak, decode error)
/// — callers degrade to "no overlay, just hatch + dashed border".
Future<ui.Image?> loadLayoutOverlayImage(
  PakCache cache,
  AppConfig config,
  int n,
) async {
  final res = await cache.getLayoutTextureFull(config, n);
  if (!res.ok || res.path == null) return null;

  final pngBytes = await File(res.path!).readAsBytes();
  final rgba = await Isolate.run(() => decodeAndAlphaMask(pngBytes));
  if (rgba == null) return null;

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba.bytes,
    rgba.width,
    rgba.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

@visibleForTesting
class MaskedRgba {
  final Uint8List bytes;
  final int width;
  final int height;
  const MaskedRgba(this.bytes, this.width, this.height);
}

@visibleForTesting
MaskedRgba? decodeAndAlphaMask(Uint8List pngBytes) {
  final decoded = img.decodePng(pngBytes);
  if (decoded == null) return null;
  for (final p in decoded) {
    final r = p.r, g = p.g, b = p.b;
    final maxCh = r > g ? (r > b ? r : b) : (g > b ? g : b);
    p.a = maxCh < 20 ? 0 : 255;
  }
  final bytes = decoded.getBytes(order: img.ChannelOrder.rgba);
  return MaskedRgba(bytes, decoded.width, decoded.height);
}
