import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_file.dart';
import 'package:rr_movie_workshop/data/datatable/name_table_extender.dart';
import 'package:rr_movie_workshop/data/datatable/row_synthesizer.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';

/// Tests the row synthesiser entirely from synthetic inputs — no base game
/// fixtures required. Each test asserts byte-level field placement against
/// the Python reference layout (RR_VHS_Tool.py:3496-3604).
///
/// We construct a stub UAsset wrapping an empty NameTable so the
/// NameTableExtender can hand out FName indices starting at 0 for the
/// synthesiser to embed in rows.
void main() {
  UAsset emptyUAsset() => UAsset(
        rawBytes: Uint8List(0),
        packageName: '',
        packageNameLengthOffset: 0,
        packageSummaryOffset: 0,
        nameCount: 0,
        nameOffset: 0,
        exportOffset: 0,
        serialSizeOffset: 0,
        serialSize: 0,
        nameTable:
            const NameTable(entries: [], regionStart: 0, regionEnd: 0),
      );

  RowSynthesizer makeSynth({
    RowSchema schema = RowSchema.v2,
    int rowKeyNumber = 0x05001780,
    int genreByte = 0x04,
    int placementByte = 0x01,
    int colorPaletteByte = 0,
    Random? random,
    NameTableExtender? overrideExtender,
  }) {
    return RowSynthesizer(
      schema: schema,
      rowKeyNumber: rowKeyNumber,
      genreByte: genreByte,
      placementByte: placementByte,
      colorPaletteByte: colorPaletteByte,
      names: overrideExtender ?? NameTableExtender(emptyUAsset()),
      random: random,
    );
  }

  const horror1 = SlotData(
    bkgTex: 'T_Bkg_Hor_01',
    pnName: 'The Sixth Sense',
    ls: 7,
    lsc: 4,
    sku: 5304473,
    ntu: false,
  );

  group('buildRow — V2 (standard genre, 2-digit BI)', () {
    test('row size = 72 with 2-digit BI; every field at the V2 offset', () {
      final s = makeSynth();
      final row = s.buildRow(0, horror1);
      expect(row.length, 72);

      final view = ByteData.sublistView(row);

      // RowKey FName: idx for "1" = 0 (first registered name in this synth).
      expect(view.getUint32(0, Endian.little), 0);
      expect(view.getUint32(4, Endian.little), 0x05001780);

      // ProductName FName: idx for "The Sixth Sense" = 2 (after "1" and "2").
      expect(view.getUint32(8, Endian.little), 2);
      expect(view.getInt32(12, Endian.little), 0);

      // SubjectImage FString: 9 bytes "T_Sub_01\0".
      expect(view.getInt32(16, Endian.little), 9);
      expect(row.sublist(20, 29), [
        0x54, 0x5F, 0x53, 0x75, 0x62, 0x5F, 0x30, 0x31, 0x00,
      ]);

      // BI FString: 13 bytes "T_Bkg_Hor_01\0".
      expect(view.getInt32(29, Endian.little), 13);
      // afterBi = 33 + 13 = 46
      const afterBi = 46;

      // SubjectName == ProductName (idx 2)
      expect(view.getUint32(afterBi, Endian.little), 2);
      expect(view.getInt32(afterBi + 4, Endian.little), 0);

      expect(row[afterBi + 8], 0x04); // genre
      expect(row[afterBi + 9], 0x01); // placement (V2 only)

      // V2 tail: LS@+10, LSC@+14, SKU@+18, NextKey@+22
      expect(view.getInt32(afterBi + 10, Endian.little), 7);
      expect(view.getInt32(afterBi + 14, Endian.little), 4);
      expect(view.getInt32(afterBi + 18, Endian.little), 5304473);
      // NextKey = idx for "2" = 1
      expect(view.getUint32(afterBi + 22, Endian.little), 1);
    });

    test('3-digit BI (custom slot) produces a 73-byte V2 row', () {
      final s = makeSynth();
      final row = s.buildRow(
        0,
        const SlotData(
          bkgTex: 'T_Bkg_Hor_001',
          pnName: 'Custom',
          ls: 3,
          lsc: 2,
          sku: 1234567,
        ),
      );
      expect(row.length, 73);
      final view = ByteData.sublistView(row);
      expect(view.getInt32(29, Endian.little), 14); // BI len
      const afterBi = 47; // 33 + 14
      expect(view.getInt32(afterBi + 18, Endian.little), 1234567);
    });
  });

  group('buildRow — V1 (no Placement, no ColorPalette)', () {
    test('row size = 71 with 2-digit BI; tail offsets per V1', () {
      final s = makeSynth(schema: RowSchema.v1);
      final row = s.buildRow(0, horror1);
      expect(row.length, 71);
      final view = ByteData.sublistView(row);
      const afterBi = 46;
      expect(row[afterBi + 8], 0x04); // genre
      // V1 has NO placement byte at +9 — that position is the low byte of LS.
      // V1 tail: LS@+9, LSC@+13, SKU@+17, NextKey@+21
      expect(view.getInt32(afterBi + 9, Endian.little), 7);
      expect(view.getInt32(afterBi + 13, Endian.little), 4);
      expect(view.getInt32(afterBi + 17, Endian.little), 5304473);
      expect(view.getUint32(afterBi + 21, Endian.little), 1);
    });
  });

  group('buildRow — V3 (Placement + ColorPalette)', () {
    test('row size = 73 with 2-digit BI; CP byte at expected offset', () {
      final s = makeSynth(schema: RowSchema.v3, colorPaletteByte: 0x02);
      final row = s.buildRow(0, horror1);
      expect(row.length, 73);
      final view = ByteData.sublistView(row);
      const afterBi = 46;
      expect(row[afterBi + 8], 0x04);
      expect(row[afterBi + 9], 0x01); // placement
      expect(view.getInt32(afterBi + 10, Endian.little), 7); // LS
      expect(view.getInt32(afterBi + 14, Endian.little), 4); // LSC
      expect(row[afterBi + 18], 0x02); // ColorPalette
      expect(view.getInt32(afterBi + 19, Endian.little), 5304473); // SKU
      expect(view.getUint32(afterBi + 23, Endian.little), 1); // NextKey
    });
  });

  group('buildRows — multiple slots + sentinel + linked list', () {
    test('three V2 rows: linked list connects 1→2→3→sentinel→0', () {
      final s = makeSynth();
      final slots = [
        const SlotData(
            bkgTex: 'T_Bkg_Hor_01', pnName: 'A', ls: 1, lsc: 1, sku: 100),
        const SlotData(
            bkgTex: 'T_Bkg_Hor_02', pnName: 'B', ls: 2, lsc: 2, sku: 200),
        const SlotData(
            bkgTex: 'T_Bkg_Hor_03', pnName: 'C', ls: 3, lsc: 3, sku: 300),
      ];
      final out = s.buildRows(slots);

      // Three real rows of 72 bytes + a 72-byte sentinel = 288 bytes.
      expect(out.length, 4 * 72);

      final view = ByteData.sublistView(out);
      // afterBi for any V2 row with 2-digit BI = 46.
      const afterBi = 46;
      const v2NextKeyOff = 22;

      // Row 0: NextKey → idx for "2"
      final r0Next = view.getUint32(0 + afterBi + v2NextKeyOff, Endian.little);
      // Row 1: NextKey → idx for "3"
      final r1Next = view.getUint32(72 + afterBi + v2NextKeyOff, Endian.little);
      // Row 2 (last real): NextKey → idx for "4" (sentinel's row key)
      final r2Next =
          view.getUint32(144 + afterBi + v2NextKeyOff, Endian.little);
      // Sentinel: NextKey → 0 (end)
      final senNext =
          view.getUint32(216 + afterBi + v2NextKeyOff, Endian.little);

      // Row keys are registered in order "1","2","3","4","End of List", so
      // their FName indices in this empty-extender setup are 0..4 — followed
      // by the title entries "A","B","C" at 5..7.
      expect(r0Next, 1); // points to "2"
      expect(r1Next, 2); // points to "3"
      expect(r2Next, 3); // points to "4" (sentinel)
      expect(senNext, 0); // end of list

      // Sentinel's ProductName + SubjectName both reference "End of List".
      // It was registered after "1".."4", so its idx is 4.
      final senPn = view.getUint32(216 + 8, Endian.little);
      final senSn = view.getUint32(216 + afterBi, Endian.little);
      expect(senPn, 4);
      expect(senSn, 4);

      // Sentinel's SKU (V2 SKU offset = +18) is 0.
      expect(view.getInt32(216 + afterBi + 18, Endian.little), 0);
    });
  });

  group('LayoutStyle random fallback', () {
    test('ls == 0 picks a value in [1, 5] (deterministic with seed)', () {
      final s = makeSynth(random: Random(42));
      final row = s.buildRow(
        0,
        const SlotData(
            bkgTex: 'T_Bkg_Hor_01',
            pnName: 'X',
            ls: 0,
            lsc: 1,
            sku: 1),
      );
      final view = ByteData.sublistView(row);
      final ls = view.getInt32(46 + 10, Endian.little);
      expect(ls, inInclusiveRange(1, 5));
    });
  });

  group('Title overrides', () {
    test('override changes ProductName + SubjectName indices, not RowKey',
        () {
      final s = makeSynth();
      final out = s.buildRows(
        [horror1],
        titleOverrides: {'The Sixth Sense': 'My Replacement'},
      );

      // Row 0 ProductName idx points at "My Replacement", not "The Sixth Sense".
      // Names registered in order: "1", "2", "End of List", then ProductName.
      // With override, the override string is what gets registered (3 → "My Replacement"),
      // and the original "The Sixth Sense" is never inserted.
      final entries = s.names.entries;
      expect(entries.any((e) => e.value == 'My Replacement'), isTrue);
      expect(entries.any((e) => e.value == 'The Sixth Sense'), isFalse);

      final view = ByteData.sublistView(out);
      final pnIdxRow0 = view.getUint32(8, Endian.little);
      final pnIdxSentinel = view.getUint32(72 + 8, Endian.little);
      final myReplacementIdx =
          entries.indexWhere((e) => e.value == 'My Replacement');
      final endOfListIdx =
          entries.indexWhere((e) => e.value == 'End of List');
      expect(pnIdxRow0, myReplacementIdx);
      expect(pnIdxSentinel, endOfListIdx);
    });
  });
}
