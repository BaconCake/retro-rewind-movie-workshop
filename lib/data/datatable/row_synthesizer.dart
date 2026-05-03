import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'datatable_file.dart';
import 'name_table_extender.dart';
import 'slot_data.dart';

/// Tail layout for each row schema. Offsets are relative to `after_bi` (= the
/// first byte after the BackgroundImage FString in a row). All schemas share
/// the same prefix [RowKey FName | ProductName FName | SI FString | BI
/// FString], differing only in what fields appear after BI and where.
///
/// Verified against base-game uexps via slice 2c-A's parser (RR_VHS_Tool.py:
/// 3496-3512 has the same offsets).
class _SchemaTail {
  final int tailSize;
  final bool hasPlacement;
  final bool hasColorPalette;
  final int lsOffset;
  final int lscOffset;
  final int? cpOffset;
  final int skuOffset;
  final int nextKeyOffset;

  const _SchemaTail({
    required this.tailSize,
    required this.hasPlacement,
    required this.hasColorPalette,
    required this.lsOffset,
    required this.lscOffset,
    required this.cpOffset,
    required this.skuOffset,
    required this.nextKeyOffset,
  });

  static const v1 = _SchemaTail(
    tailSize: 25,
    hasPlacement: false,
    hasColorPalette: false,
    lsOffset: 9,
    lscOffset: 13,
    cpOffset: null,
    skuOffset: 17,
    nextKeyOffset: 21,
  );

  static const v2 = _SchemaTail(
    tailSize: 26,
    hasPlacement: true,
    hasColorPalette: false,
    lsOffset: 10,
    lscOffset: 14,
    cpOffset: null,
    skuOffset: 18,
    nextKeyOffset: 22,
  );

  static const v3 = _SchemaTail(
    tailSize: 27,
    hasPlacement: true,
    hasColorPalette: true,
    lsOffset: 10,
    lscOffset: 14,
    cpOffset: 18,
    skuOffset: 19,
    nextKeyOffset: 23,
  );

  static _SchemaTail forSchema(RowSchema s) {
    switch (s) {
      case RowSchema.v1:
        return v1;
      case RowSchema.v2:
        return v2;
      case RowSchema.v3:
        return v3;
    }
  }
}

/// Synthesises DataTable rows from slot data, matching the per-row layout
/// used by `CleanDataTableBuilder.build` (RR_VHS_Tool.py:3483-3604).
///
/// Output strategy mirrors Python verbatim:
///
///   - One row per slot (not 77/slot like the base game).
///   - SubjectImage is always `"T_Sub_01\0"` (9 bytes); the per-slot subject
///     texture is delivered separately, so duplicating row variants gives
///     no behavioural benefit.
///   - BackgroundImage is the slot's `bkgTex` plus null. 2-digit names
///     produce 13-byte BI FStrings, 3-digit names produce 14-byte — rows in
///     the same uexp can have different sizes.
///   - A sentinel "End of List" row is appended after the real rows. The
///     game's row picker skips the last row, so the sentinel is sacrificial
///     and keeps every real movie pickable.
///   - Rows are linked: each row's NextRowKeyIdx FName index points to the
///     next row's RowKey name. The sentinel terminates with NextRowKeyIdx=0.
///
/// New FName entries (row keys "1".."N+1", titles, "End of List") are added
/// to the supplied [NameTableExtender] on demand. The caller then asks the
/// extender for the rebuilt uasset bytes.
class RowSynthesizer {
  final RowSchema schema;
  final int rowKeyNumber; // RK_NUM
  final int genreByte;
  final int placementByte;
  final int colorPaletteByte; // V3 only
  final NameTableExtender names;
  final Random _random;

  RowSynthesizer({
    required this.schema,
    required this.rowKeyNumber,
    required this.genreByte,
    required this.placementByte,
    this.colorPaletteByte = 0,
    required this.names,
    Random? random,
  }) : _random = random ?? Random();

  /// Convenience: construct from a parsed base-game uexp. Pulls schema /
  /// rowKeyNumber / genre / placement straight off the [UExp] view and lets
  /// the caller supply only the appended-to extender.
  factory RowSynthesizer.fromBase({
    required UExp baseUexp,
    required NameTableExtender names,
    int colorPaletteByte = 0,
    Random? random,
  }) {
    return RowSynthesizer(
      schema: baseUexp.schema,
      rowKeyNumber: baseUexp.rowKeyNumber,
      genreByte: baseUexp.genreByte,
      placementByte: baseUexp.placementByte,
      colorPaletteByte: colorPaletteByte,
      names: names,
      random: random,
    );
  }

  /// Build the row block for [slots] plus the trailing "End of List" sentinel.
  /// Returns concatenated row bytes ready to splice into a uexp.
  ///
  /// [titleOverrides] maps `slot.pnName` → display title. Rows whose pn_name
  /// is not in the map render with the original `slot.pnName`. The override
  /// affects both ProductName and SubjectName FNames (they always share an
  /// index per Python, RR_VHS_Tool.py:3547).
  Uint8List buildRows(
    List<SlotData> slots, {
    Map<String, String> titleOverrides = const {},
  }) {
    if (slots.isEmpty) return Uint8List(0);

    // Pre-register all row key strings ("1".."N+1") and all titles so the
    // name-table indices we look up are stable for the whole row block.
    for (var i = 0; i < slots.length + 1; i++) {
      names.indexOf((i + 1).toString());
    }
    names.indexOf('End of List');

    final tail = _SchemaTail.forSchema(schema);
    final rowBuf = BytesBuilder(copy: false);
    final rowOffsets = <int>[]; // start offset of each emitted row
    var lastRowSize = schema.size;

    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final title = titleOverrides[slot.pnName] ?? slot.pnName;
      final pnIdx = names.indexOf(title);
      final rkIdx = names.indexOf((i + 1).toString());
      final nextRkIdx = names.indexOf((i + 2).toString());
      final row = _buildRow(
        tail,
        slot: slot,
        rowKeyNameIdx: rkIdx,
        productNameIdx: pnIdx,
        nextRowKeyNameIdx: nextRkIdx,
      );
      rowOffsets.add(rowBuf.length);
      rowBuf.add(row);
      lastRowSize = row.length;
    }

    // Sentinel: clone the last real row's schema/BI layout, swap fields.
    final sentinelRkIdx = names.indexOf((slots.length + 1).toString());
    final sentinelPnIdx = names.indexOf('End of List');
    final sentinel = _buildSentinel(
      tail,
      cloneFromRow: rowBuf.toBytes().sublist(
            rowBuf.length - lastRowSize,
            rowBuf.length,
          ),
      rowKeyNameIdx: sentinelRkIdx,
      sentinelTitleNameIdx: sentinelPnIdx,
    );

    // Concatenate real rows + sentinel into one buffer, then patch the last
    // real row's NextRowKeyIdx to point at the sentinel's row-key name.
    final all = Uint8List(rowBuf.length + sentinel.length)
      ..setRange(0, rowBuf.length, rowBuf.toBytes())
      ..setRange(rowBuf.length, rowBuf.length + sentinel.length, sentinel);
    final lastRowStart = rowBuf.length - lastRowSize;
    final lastRowAfterBi = _afterBiOffset(all, lastRowStart);
    ByteData.sublistView(all).setUint32(
      lastRowAfterBi + tail.nextKeyOffset,
      sentinelRkIdx,
      Endian.little,
    );
    return all;
  }

  /// Build a single row — exposed for tests; real callers use [buildRows].
  /// Registers row-key names before the title so FName indices end up in
  /// the same order [buildRows] would produce when called with one slot.
  Uint8List buildRow(int slotIndex, SlotData slot, {String? titleOverride}) {
    final rkIdx = names.indexOf((slotIndex + 1).toString());
    final nextRkIdx = names.indexOf((slotIndex + 2).toString());
    final title = titleOverride ?? slot.pnName;
    final pnIdx = names.indexOf(title);
    return _buildRow(
      _SchemaTail.forSchema(schema),
      slot: slot,
      rowKeyNameIdx: rkIdx,
      productNameIdx: pnIdx,
      nextRowKeyNameIdx: nextRkIdx,
    );
  }

  Uint8List _buildRow(
    _SchemaTail tail, {
    required SlotData slot,
    required int rowKeyNameIdx,
    required int productNameIdx,
    required int nextRowKeyNameIdx,
  }) {
    final biStr = utf8.encode(slot.bkgTex);
    final biLen = biStr.length + 1; // +null
    final rowSize = 33 + biLen + tail.tailSize;
    final row = Uint8List(rowSize);
    final view = ByteData.sublistView(row);

    // Prefix [0..29) — RowKey FName, ProductName FName, SI FString.
    view.setUint32(0, rowKeyNameIdx, Endian.little);
    view.setUint32(4, rowKeyNumber, Endian.little);
    view.setUint32(8, productNameIdx, Endian.little);
    // ProductName number stays 0 — Python writes 0 explicitly.
    view.setInt32(16, 9, Endian.little); // SI FString length
    row.setRange(20, 29, _tSub01);

    // BI FString [29..29+4+biLen)
    view.setInt32(29, biLen, Endian.little);
    row.setRange(33, 33 + biStr.length, biStr);
    // Trailing null already in place from Uint8List zero-init.

    final afterBi = 33 + biLen;

    // SubjectName FName (always equals ProductName per Python:3547)
    view.setUint32(afterBi, productNameIdx, Endian.little);
    // SubjectName number stays 0.

    row[afterBi + 8] = genreByte;
    if (tail.hasPlacement) {
      row[afterBi + 9] = placementByte;
    }

    var ls = slot.ls;
    if (ls == 0) {
      ls = _random.nextInt(5) + 1;
    }
    view.setInt32(afterBi + tail.lsOffset, ls, Endian.little);
    view.setInt32(afterBi + tail.lscOffset, slot.lsc, Endian.little);
    if (tail.hasColorPalette && tail.cpOffset != null) {
      row[afterBi + tail.cpOffset!] = colorPaletteByte & 0xFF;
    }
    view.setInt32(afterBi + tail.skuOffset, slot.sku, Endian.little);
    view.setUint32(
        afterBi + tail.nextKeyOffset, nextRowKeyNameIdx, Endian.little);

    return row;
  }

  Uint8List _buildSentinel(
    _SchemaTail tail, {
    required Uint8List cloneFromRow,
    required int rowKeyNameIdx,
    required int sentinelTitleNameIdx,
  }) {
    final s = Uint8List.fromList(cloneFromRow);
    final view = ByteData.sublistView(s);

    view.setUint32(0, rowKeyNameIdx, Endian.little);
    view.setUint32(4, rowKeyNumber, Endian.little);
    view.setUint32(8, sentinelTitleNameIdx, Endian.little);
    view.setInt32(12, 0, Endian.little);

    final afterBi = _afterBiOffset(s, 0);
    view.setUint32(afterBi, sentinelTitleNameIdx, Endian.little);
    view.setInt32(afterBi + 4, 0, Endian.little);
    view.setInt32(afterBi + tail.skuOffset, 0, Endian.little); // SKU = 0
    view.setUint32(afterBi + tail.nextKeyOffset, 0, Endian.little); // end of list
    return s;
  }

  /// Computes `after_bi` for a row sliced from a larger buffer. The caller
  /// passes [rowBuf] containing the row plus optionally trailing data, and
  /// [rowStart] giving the row's first byte. Reads BI FString length at
  /// rowStart+29 and returns rowStart+33+biLen.
  static int _afterBiOffset(Uint8List rowBuf, int rowStart) {
    final view = ByteData.sublistView(rowBuf);
    final biLen = view.getInt32(rowStart + 29, Endian.little);
    return rowStart + 33 + biLen;
  }
}

const List<int> _tSub01 = [
  0x54, 0x5F, 0x53, 0x75, 0x62, 0x5F, // "T_Sub_"
  0x30, 0x31, 0x00, // "01\0"
];
