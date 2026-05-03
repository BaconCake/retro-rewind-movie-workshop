import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/domain/custom_slot_naming.dart';

void main() {
  group('formatCustomBkgTex', () {
    test('zero-pads to 3 digits below 100', () {
      expect(formatCustomBkgTex('Dra', 1), 'T_Bkg_Dra_001');
      expect(formatCustomBkgTex('Hor', 99), 'T_Bkg_Hor_099');
    });
    test('no padding at 100 and above', () {
      expect(formatCustomBkgTex('Dra', 100), 'T_Bkg_Dra_100');
      expect(formatCustomBkgTex('Dra', 999), 'T_Bkg_Dra_999');
    });
  });

  group('nextFreeSlotIndex', () {
    test('returns 1 when nothing exists', () {
      expect(nextFreeSlotIndex('Dra', const []), 1);
    });
    test('fills the lowest gap (does not just append)', () {
      // 1 and 3 are taken — should return 2, not 4.
      expect(
        nextFreeSlotIndex('Dra', const ['T_Bkg_Dra_001', 'T_Bkg_Dra_003']),
        2,
      );
    });
    test('skips the contiguous block then returns next', () {
      expect(
        nextFreeSlotIndex('Dra', const [
          'T_Bkg_Dra_001',
          'T_Bkg_Dra_002',
          'T_Bkg_Dra_003',
        ]),
        4,
      );
    });
    test('ignores names from other genres', () {
      // Only Drama prefix counts — Horror entries are unrelated.
      expect(
        nextFreeSlotIndex('Dra', const [
          'T_Bkg_Hor_001',
          'T_Bkg_Hor_002',
          'T_Bkg_Dra_001',
        ]),
        2,
      );
    });
    test('ignores malformed names without crashing', () {
      expect(
        nextFreeSlotIndex('Dra', const [
          'T_Bkg_Dra_001',
          'T_Bkg_Dra_garbage',
          'not even close',
        ]),
        2,
      );
    });
    test('handles 3-digit and 1-digit alike (parses int regardless)', () {
      // Python\'s int(bkg[len(prefix):]) treats "001" and "1" both as 1.
      expect(
        nextFreeSlotIndex('Dra', const [
          'T_Bkg_Dra_001',
          'T_Bkg_Dra_2',
        ]),
        3,
      );
    });
  });

  group('customSlotSubTex', () {
    test('first custom slot → T_Sub_78', () {
      expect(customSlotSubTex(1), 'T_Sub_78');
    });
    test('22nd custom slot → T_Sub_99 (last before wrap)', () {
      expect(customSlotSubTex(22), 'T_Sub_99');
    });
    test('23rd custom slot wraps back to T_Sub_78', () {
      expect(customSlotSubTex(23), 'T_Sub_78');
    });
    test('45th custom slot wraps twice → T_Sub_78 again', () {
      // (45 - 1) % 22 = 0 → T_Sub_78
      expect(customSlotSubTex(45), 'T_Sub_78');
    });
  });
}
