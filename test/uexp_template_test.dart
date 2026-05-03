import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/uexp_template.dart';

void main() {
  group('uexp template constants (Python parity)', () {
    test('template is exactly 1702 bytes', () {
      // Python asserts the same: RR_VHS_Tool.py:1071.
      expect(kTBkgUexpTemplate.length, 1702);
    });

    test('template ends with the Unreal package tail magic', () {
      // The last 4 bytes of every Unreal uexp are the package tail magic
      // 0xC1832A9E.  The template embeds them at the end.
      final tail = kTBkgUexpTemplate.sublist(
          kTBkgUexpTemplate.length - 4, kTBkgUexpTemplate.length);
      expect(tail, [0xC1, 0x83, 0x2A, 0x9E]);
    });

    test('inline mip map matches the canonical (level, offset, size) tuples',
        () {
      // Locked-in from RR_VHS_Tool.py:1077-1086.  Changing any number here
      // would silently corrupt every injected texture.
      expect(kUexpInlineMipMap, [
        (5, 0x00C2, 1024),
        (6, 0x04D2, 256),
        (7, 0x05E2, 64),
        (8, 0x0632, 16),
        (9, 0x0652, 8),
        (10, 0x066A, 8),
        (11, 0x0682, 8),
      ]);
    });

    test('every mip slice fits inside the template', () {
      for (final (_, offset, size) in kUexpInlineMipMap) {
        expect(offset + size, lessThanOrEqualTo(kTBkgUexpTemplate.length),
            reason: 'mip at offset $offset (size $size) overflows template');
      }
    });

    test('ubulk size constants match the formulas in Python', () {
      // BKG_UBULK_SIZE = (W/4) * (H/4) * 8.  RR_VHS_Tool.py:5590.
      expect(kBkgUbulkSize, 1048576);
      // TNEW_UBULK_SIZE = sum over 5 mip levels.  RR_VHS_Tool.py:5591-5594.
      expect(kTNewUbulkSize, 1396736);
    });
  });
}
