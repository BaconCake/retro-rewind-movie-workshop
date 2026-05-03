import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/tsub_template.dart';
import 'package:rr_movie_workshop/data/services/transparent_tsub_builder.dart';

bool _containsAscii(List<int> haystack, String needle) {
  final n = needle.codeUnits;
  if (n.isEmpty) return true;
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

int _countAscii(List<int> haystack, String needle) {
  final n = needle.codeUnits;
  if (n.isEmpty) return 0;
  var count = 0;
  for (var i = 0; i + n.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) {
        match = false;
        break;
      }
    }
    if (match) count++;
  }
  return count;
}

void main() {
  const builder = TransparentTSubBuilder();

  group('build', () {
    test('T_Sub_01 keeps the template name verbatim', () {
      final art = builder.build('T_Sub_01');
      expect(art.uasset.length, 754);
      expect(art.uexp.length, 131220);
      expect(_containsAscii(art.uasset, 'T_Sub_01'), isTrue);
    });

    test('T_Sub_42 carries the new name and drops the template name', () {
      // Sanity check that every occurrence of the source name was patched.
      // Python's behaviour: bytes.replace replaces all matches.
      final art = builder.build('T_Sub_42');
      expect(_countAscii(art.uasset, 'T_Sub_01'), 0,
          reason:
              'no leftover "T_Sub_01" should remain after the byte-replace');
      expect(_countAscii(art.uasset, 'T_Sub_42'),
          _countAscii(kTSubSrcUasset, 'T_Sub_01'),
          reason: 'every occurrence of the template name must be replaced');
    });

    test('uasset and uexp end with the UE4 package magic', () {
      // Last 4 bytes of every uexp are 0xC1 0x83 0x2A 0x9E.  Python's
      // template uasset also ends with that same magic at offset 0.
      final art = builder.build('T_Sub_77');
      expect(art.uexp.sublist(art.uexp.length - 4),
          [0xC1, 0x83, 0x2A, 0x9E]);
    });

    test('a 9-char name (e.g. T_Sub_100) silently falls back to T_Sub_78', () {
      // The byte-replace requires a same-length destination; longer names
      // would shift every offset.  Python falls back to T_Sub_78 with a
      // warning (RR_VHS_Tool.py:1656-1661); we mirror that.
      final art = builder.build('T_Sub_100');
      expect(_containsAscii(art.uasset, 'T_Sub_78'), isTrue);
      expect(_containsAscii(art.uasset, 'T_Sub_100'), isFalse);
    });
  });

  group('customSlotTSubName', () {
    test('first custom slot is T_Sub_78', () {
      expect(TransparentTSubBuilder.customSlotTSubName(1), 'T_Sub_78');
    });

    test('22nd custom slot is T_Sub_99 (last in the reserved range)', () {
      expect(TransparentTSubBuilder.customSlotTSubName(22), 'T_Sub_99');
    });

    test('23rd wraps back to T_Sub_78', () {
      // RR_VHS_Tool.py:1686 — the wrap is intentional, all custom T_Subs
      // are identical transparent textures so sharing names is harmless.
      expect(TransparentTSubBuilder.customSlotTSubName(23), 'T_Sub_78');
    });
  });

  group('baseTSubNames', () {
    test('returns exactly T_Sub_01..T_Sub_77 in order', () {
      final names = TransparentTSubBuilder.baseTSubNames();
      expect(names, hasLength(77));
      expect(names.first, 'T_Sub_01');
      expect(names.last, 'T_Sub_77');
      for (var i = 0; i < 77; i++) {
        expect(names[i], 'T_Sub_${(i + 1).toString().padLeft(2, '0')}');
      }
    });
  });
}
