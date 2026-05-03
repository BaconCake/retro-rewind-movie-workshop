import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/tsub_template.dart';

void main() {
  group('T_Sub template constants (Python parity)', () {
    test('uasset template is exactly 754 bytes', () {
      // Python asserts the same: RR_VHS_Tool.py:1097.
      expect(kTSubSrcUasset.length, 754);
    });

    test('uexp header template is exactly 144 bytes', () {
      // RR_VHS_Tool.py:1098.
      expect(kTSubUexpHeader.length, 144);
    });

    test('mip tail is exactly 28 bytes', () {
      // RR_VHS_Tool.py:1670 — the metadata trailer of the pixel area.
      expect(kTSubMipTail.length, 28);
    });

    test('uasset template embeds the literal name "T_Sub_01"', () {
      // The clone path byte-replaces this string per output name.  If it
      // disappeared from the template, every cloned T_Sub would silently
      // keep the wrong name.
      final needle = 'T_Sub_01'.codeUnits;
      var hit = false;
      for (var i = 0; i + needle.length <= kTSubSrcUasset.length; i++) {
        var match = true;
        for (var j = 0; j < needle.length; j++) {
          if (kTSubSrcUasset[i + j] != needle[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          hit = true;
          break;
        }
      }
      expect(hit, isTrue,
          reason: '"T_Sub_01" must appear at least once in the template');
    });
  });

  group('makeTransparentDxt1Block512', () {
    test('produces exactly 131,072 bytes (512×512 DXT1, mip 0)', () {
      expect(makeTransparentDxt1Block512().length, 131072);
    });

    test('every block matches the canonical transparent DXT1 layout', () {
      // Each 8-byte block is `c0=0x0000 (LE), c1=0xFFFF (LE),
      // indices=0xFFFFFFFF`.  Python: RR_VHS_Tool.py:1059-1062.
      final pixels = makeTransparentDxt1Block512();
      const expected = [
        0x00, 0x00, // c0
        0xFF, 0xFF, // c1
        0xFF, 0xFF, 0xFF, 0xFF, // indices
      ];
      for (var blk = 0; blk < 128 * 128; blk++) {
        for (var i = 0; i < 8; i++) {
          expect(pixels[blk * 8 + i], expected[i],
              reason:
                  'block #$blk byte $i should be 0x${expected[i].toRadixString(16)}');
        }
      }
    });
  });

  group('layout invariants', () {
    test('total uexp size matches Python (144 + 131044 + 28 + 4 = 131,220)',
        () {
      expect(
          kTSubUexpHeader.length + kTSubPixelBytes + kTSubMipTail.length + 4,
          131220);
    });

    test('kTSubCustomBase is 78 (first reserved custom T_Sub number)', () {
      expect(kTSubCustomBase, 78);
    });
  });
}
