import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rr_movie_workshop/data/services/layout_overlay_loader.dart';

/// Verifies the alpha-mask Python applies to the layout texture before
/// compositing it on the canvas (RR_VHS_Tool.py:12848-12857): pixels
/// whose brightest channel is below 20 become fully transparent so the
/// user's cover shows through the "window" area of the cassette body.
void main() {
  group('decodeAndAlphaMask', () {
    test('dark pixels (max channel < 20) become transparent', () {
      final pngBytes = _buildSwatchPng();
      final result = decodeAndAlphaMask(pngBytes)!;
      expect(result.width, 4);
      expect(result.height, 1);

      // Pixel 0 — pure black (0,0,0): max = 0 < 20 → alpha 0
      expect(result.bytes[0 * 4 + 3], 0);
      // Pixel 1 — dark but brightest channel = 19 < 20 → still alpha 0
      expect(result.bytes[1 * 4 + 3], 0);
      // Pixel 2 — brightest channel = 20 (not strictly below 20) → alpha 255
      expect(result.bytes[2 * 4 + 3], 255);
      // Pixel 3 — bright opaque white (255,255,255) → alpha 255
      expect(result.bytes[3 * 4 + 3], 255);
    });

    test('RGB channels are preserved — only alpha gets rewritten', () {
      final pngBytes = _buildSwatchPng();
      final result = decodeAndAlphaMask(pngBytes)!;
      // Pixel 3 — white: r/g/b stay 255 after masking.
      expect(result.bytes[3 * 4 + 0], 255);
      expect(result.bytes[3 * 4 + 1], 255);
      expect(result.bytes[3 * 4 + 2], 255);
      // Pixel 2 — (10, 0, 20): channels remain even though alpha = 255.
      expect(result.bytes[2 * 4 + 0], 10);
      expect(result.bytes[2 * 4 + 1], 0);
      expect(result.bytes[2 * 4 + 2], 20);
    });

    test('returns null for un-decodable bytes', () {
      final junk = Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7]);
      expect(decodeAndAlphaMask(junk), isNull);
    });
  });
}

/// Builds a 4×1 PNG with four hand-picked swatches that bracket the
/// `max(r,g,b) < 20` threshold.
Uint8List _buildSwatchPng() {
  final image = img.Image(width: 4, height: 1, numChannels: 4);
  // (r, g, b) — alpha starts at 255 and is rewritten by the loader.
  image.setPixelRgba(0, 0,  0,  0,  0, 255);   // black, max = 0
  image.setPixelRgba(1, 0, 19, 10, 15, 255);   // max = 19  (just below 20)
  image.setPixelRgba(2, 0, 10,  0, 20, 255);   // max = 20  (boundary, keeps opacity)
  image.setPixelRgba(3, 0, 255, 255, 255, 255); // white, max = 255
  return Uint8List.fromList(img.encodePng(image));
}
