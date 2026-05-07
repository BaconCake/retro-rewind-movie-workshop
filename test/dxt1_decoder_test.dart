import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/services/dxt1_decoder.dart';

/// Tests for the pure-Dart DXT1 (BC1) decoder used by the layout-texture
/// preloader (slice 4f).  Python has no equivalent test coverage — these
/// lock in parity with the Wikipedia / DirectX 10 spec on a handful of
/// hand-computed blocks.
void main() {
  // Build a single 4×4 block (8 bytes): c0, c1 (RGB565 little-endian) +
  // 32-bit row-major index buffer.
  Uint8List block(int c0, int c1, int indices) {
    final b = ByteData(8);
    b.setUint16(0, c0, Endian.little);
    b.setUint16(2, c1, Endian.little);
    b.setUint32(4, indices, Endian.little);
    return b.buffer.asUint8List();
  }

  // Read the RGBA quad at (x,y) inside a [width]-pixel-wide RGBA buffer.
  ({int r, int g, int b, int a}) px(Uint8List rgba, int width, int x, int y) {
    final o = (y * width + x) * 4;
    return (r: rgba[o], g: rgba[o + 1], b: rgba[o + 2], a: rgba[o + 3]);
  }

  group('decodeDxt1 — single 4×4 block', () {
    test('white c0 + black c1, all index 0 → solid white', () {
      // RGB565 white = 0xFFFF; black = 0x0000.  c0 > c1 → 4-colour mode.
      // index buffer = 0x00000000 → every pixel uses palette[0] = white.
      final rgba = decodeDxt1(block(0xFFFF, 0x0000, 0x00000000), 4, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final p = px(rgba, 4, x, y);
          expect(p, (r: 255, g: 255, b: 255, a: 255),
              reason: '($x,$y) should be opaque white');
        }
      }
    });

    test('all index 1 → solid c1', () {
      // c0 = white, c1 = pure red (RGB565 0xF800 → r5=31, g6=0, b5=0).
      // index 1 picks c1.
      final rgba =
          decodeDxt1(block(0xFFFF, 0xF800, 0x55555555), 4, 4);
      // 0x55555555 = 0b 01 01 01 01 ... → every pixel index = 1.
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final p = px(rgba, 4, x, y);
          expect(p, (r: 255, g: 0, b: 0, a: 255));
        }
      }
    });

    test('4-colour mode: index 2 = (2*c0 + c1)/3, index 3 = (c0 + 2*c1)/3',
        () {
      // c0 = white (255,255,255), c1 = black (0,0,0); c0 > c1 so 4-colour.
      // palette[2] = (2*255 + 0)/3 = 170 (integer floor).
      // palette[3] = (255 + 2*0)/3  =  85.
      // Indices: 0xAAAAAAAA = 0b 10 10 ... → every pixel = 2.
      final rgba2 =
          decodeDxt1(block(0xFFFF, 0x0000, 0xAAAAAAAA), 4, 4);
      final p2 = px(rgba2, 4, 0, 0);
      expect(p2, (r: 170, g: 170, b: 170, a: 255));

      // Indices: 0xFFFFFFFF = 0b 11 11 ... → every pixel = 3.
      final rgba3 =
          decodeDxt1(block(0xFFFF, 0x0000, 0xFFFFFFFF), 4, 4);
      final p3 = px(rgba3, 4, 0, 0);
      expect(p3, (r: 85, g: 85, b: 85, a: 255));
    });

    test('3-colour + transparent mode: index 3 → fully transparent', () {
      // c0 < c1 (white > black, so we *swap* — black, white).
      // c0 = 0x0000 (black), c1 = 0xFFFF (white) ⇒ c0 <= c1 → 3-colour
      // mode.  palette[2] = (0 + 255)/2 = 127, palette[3] = (0,0,0,0).
      // Indices 0xFFFFFFFF → all index 3.
      final rgba =
          decodeDxt1(block(0x0000, 0xFFFF, 0xFFFFFFFF), 4, 4);
      final p = px(rgba, 4, 0, 0);
      expect(p, (r: 0, g: 0, b: 0, a: 0),
          reason: 'index 3 in 3-colour mode is fully transparent');
    });

    test('row-major pixel order: bits 0-1 = (0,0), bits 2-3 = (1,0)', () {
      // c0 = 0xFFFF (white), c1 = 0xF800 (red).
      // Indices: pixel(0,0) = 0 (white), pixel(1,0) = 1 (red), rest = 0.
      // bits 0-1 = 00 (white), bits 2-3 = 01 (red) → 0b00000100 = 0x04.
      final rgba =
          decodeDxt1(block(0xFFFF, 0xF800, 0x00000004), 4, 4);
      expect(px(rgba, 4, 0, 0), (r: 255, g: 255, b: 255, a: 255));
      expect(px(rgba, 4, 1, 0), (r: 255, g: 0, b: 0, a: 255));
      expect(px(rgba, 4, 2, 0), (r: 255, g: 255, b: 255, a: 255));
      expect(px(rgba, 4, 0, 1), (r: 255, g: 255, b: 255, a: 255));
    });

    test('RGB565 → RGB888 bit replication: 0x1F → 0xFF (not 0xF8)', () {
      // c0 = pure red (r5=31 → r8 should be 255, not 248).
      final rgba =
          decodeDxt1(block(0xF800, 0x0000, 0x00000000), 4, 4);
      final p = px(rgba, 4, 0, 0);
      expect(p.r, 255, reason: 'r5=31 must replicate to r8=255');
      expect(p.g, 0);
      expect(p.b, 0);
    });
  });

  group('decodeDxt1 — multi-block layout', () {
    test('8×4 image (2 horizontal blocks): each block decodes independently',
        () {
      // Block 0 (bx=0): solid white.   8 bytes.
      // Block 1 (bx=1): solid red.     8 bytes.
      final two = Uint8List(16)
        ..setRange(0, 8, block(0xFFFF, 0x0000, 0x00000000))
        ..setRange(8, 16, block(0xF800, 0x0000, 0x00000000));
      final rgba = decodeDxt1(two, 8, 4);

      // Block 0 covers x=0..3.
      expect(px(rgba, 8, 0, 0), (r: 255, g: 255, b: 255, a: 255));
      expect(px(rgba, 8, 3, 3), (r: 255, g: 255, b: 255, a: 255));
      // Block 1 covers x=4..7.
      expect(px(rgba, 8, 4, 0), (r: 255, g: 0, b: 0, a: 255));
      expect(px(rgba, 8, 7, 3), (r: 255, g: 0, b: 0, a: 255));
    });

    test('4×8 image (2 vertical blocks): block(by=1) maps to y=4..7', () {
      final two = Uint8List(16)
        ..setRange(0, 8, block(0xFFFF, 0x0000, 0x00000000)) // top block
        ..setRange(8, 16, block(0xF800, 0x0000, 0x00000000)); // bottom
      final rgba = decodeDxt1(two, 4, 8);
      expect(px(rgba, 4, 0, 0), (r: 255, g: 255, b: 255, a: 255));
      expect(px(rgba, 4, 0, 3), (r: 255, g: 255, b: 255, a: 255));
      expect(px(rgba, 4, 0, 4), (r: 255, g: 0, b: 0, a: 255));
      expect(px(rgba, 4, 0, 7), (r: 255, g: 0, b: 0, a: 255));
    });
  });

  group('decodeDxt1 — input validation', () {
    test('throws on non-multiple-of-4 width', () {
      expect(() => decodeDxt1(Uint8List(8), 5, 4), throwsArgumentError);
    });

    test('throws on non-multiple-of-4 height', () {
      expect(() => decodeDxt1(Uint8List(8), 4, 5), throwsArgumentError);
    });

    test('throws when buffer is shorter than the implied block count', () {
      // 8×8 = 4 blocks × 8 bytes = 32, we provide 16.
      expect(() => decodeDxt1(Uint8List(16), 8, 8), throwsArgumentError);
    });

    test('output length is width * height * 4', () {
      final bytes = block(0xFFFF, 0x0000, 0);
      final rgba = decodeDxt1(bytes, 4, 4);
      expect(rgba.length, 4 * 4 * 4);
    });
  });
}
