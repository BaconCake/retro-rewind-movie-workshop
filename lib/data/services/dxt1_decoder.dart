import 'dart:typed_data';

/// Decode a DXT1 (BC1) compressed buffer to a 32-bit RGBA pixel array.
///
/// Pure port of `decode_dxt1` in RR_VHS_Tool.py — used by [PakCache] to
/// turn a base-game `T_Layout_NN_bc.ubulk` into a previewable RGBA image
/// without paying for a `texconv` round-trip on every layout.
///
/// Format reference: DirectX 10 / Wikipedia "S3 Texture Compression".
/// Each 4×4 block is 8 bytes:
///
///   * Bytes 0-1: `color0` — RGB565, little-endian.
///   * Bytes 2-3: `color1` — RGB565, little-endian.
///   * Bytes 4-7: 32-bit row-major index buffer; 2 bits per pixel.
///     Pixel `(0,0)` → bits 0-1, pixel `(1,0)` → bits 2-3, …,
///     pixel `(3,3)` → bits 30-31.
///
/// Index → palette mapping depends on whether `color0 > color1`:
///
///   * `c0 > c1` (4-colour, opaque):
///       `0` = c0, `1` = c1,
///       `2` = `(2*c0 + c1) / 3`,
///       `3` = `(c0 + 2*c1) / 3`.
///   * `c0 <= c1` (3-colour + 1-bit alpha):
///       `0` = c0, `1` = c1,
///       `2` = `(c0 + c1) / 2`,
///       `3` = transparent (RGBA all zero).
///
/// [width] and [height] must each be a multiple of 4 (DXT1's block grid).
/// Returns `width * height * 4` bytes in RGBA order, suitable for feeding
/// to `image.Image.fromBytes(... numChannels: 4)`.
Uint8List decodeDxt1(Uint8List src, int width, int height) {
  if (width % 4 != 0 || height % 4 != 0) {
    throw ArgumentError(
      'DXT1 dimensions must be multiples of 4 (got ${width}x$height)',
    );
  }
  final blocksW = width >> 2;
  final blocksH = height >> 2;
  final expectedBytes = blocksW * blocksH * 8;
  if (src.lengthInBytes < expectedBytes) {
    throw ArgumentError(
      'DXT1 buffer too small: need $expectedBytes bytes for '
      '${width}x$height, got ${src.lengthInBytes}',
    );
  }

  final out = Uint8List(width * height * 4);
  // Use a ByteData view so we can read u16/u32 in little-endian without
  // building intermediate ints from bytes ourselves.
  final view = ByteData.sublistView(src, 0, expectedBytes);

  // Reused per-block 4-entry RGBA palette (4 colours × 4 bytes).
  final palette = Uint8List(16);

  for (var by = 0; by < blocksH; by++) {
    for (var bx = 0; bx < blocksW; bx++) {
      final blockOffset = (by * blocksW + bx) * 8;
      final c0 = view.getUint16(blockOffset, Endian.little);
      final c1 = view.getUint16(blockOffset + 2, Endian.little);
      var indices = view.getUint32(blockOffset + 4, Endian.little);

      // RGB565 → RGB888 with bit replication (e.g. r5 → r8 by shifting
      // and OR-ing the high bits back in, so 0x1F → 0xFF, not 0xF8).
      final r0 = (c0 >> 11) & 0x1F;
      final g0 = (c0 >> 5) & 0x3F;
      final b0 = c0 & 0x1F;
      final r1 = (c1 >> 11) & 0x1F;
      final g1 = (c1 >> 5) & 0x3F;
      final b1 = c1 & 0x1F;

      final r0_8 = (r0 << 3) | (r0 >> 2);
      final g0_8 = (g0 << 2) | (g0 >> 4);
      final b0_8 = (b0 << 3) | (b0 >> 2);
      final r1_8 = (r1 << 3) | (r1 >> 2);
      final g1_8 = (g1 << 2) | (g1 >> 4);
      final b1_8 = (b1 << 3) | (b1 >> 2);

      palette[0] = r0_8;
      palette[1] = g0_8;
      palette[2] = b0_8;
      palette[3] = 255;
      palette[4] = r1_8;
      palette[5] = g1_8;
      palette[6] = b1_8;
      palette[7] = 255;

      if (c0 > c1) {
        // 4-colour opaque mode.
        palette[8] = (2 * r0_8 + r1_8) ~/ 3;
        palette[9] = (2 * g0_8 + g1_8) ~/ 3;
        palette[10] = (2 * b0_8 + b1_8) ~/ 3;
        palette[11] = 255;
        palette[12] = (r0_8 + 2 * r1_8) ~/ 3;
        palette[13] = (g0_8 + 2 * g1_8) ~/ 3;
        palette[14] = (b0_8 + 2 * b1_8) ~/ 3;
        palette[15] = 255;
      } else {
        // 3-colour + transparent mode.
        palette[8] = (r0_8 + r1_8) ~/ 2;
        palette[9] = (g0_8 + g1_8) ~/ 2;
        palette[10] = (b0_8 + b1_8) ~/ 2;
        palette[11] = 255;
        palette[12] = 0;
        palette[13] = 0;
        palette[14] = 0;
        palette[15] = 0;
      }

      // Walk pixels in row-major order, popping 2 bits at a time off
      // the LSB end of the 32-bit index buffer.
      for (var py = 0; py < 4; py++) {
        final dstRow = (by * 4 + py) * width;
        for (var px = 0; px < 4; px++) {
          final palIdx = (indices & 3) * 4;
          final dstOffset = (dstRow + bx * 4 + px) * 4;
          out[dstOffset] = palette[palIdx];
          out[dstOffset + 1] = palette[palIdx + 1];
          out[dstOffset + 2] = palette[palIdx + 2];
          out[dstOffset + 3] = palette[palIdx + 3];
          indices >>= 2;
        }
      }
    }
  }

  return out;
}
