import 'dart:convert';
import 'dart:typed_data';

import '../../core/constants/new_release.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/new_release_slot.dart';
import '../services/pak_cache.dart';
import 'datatable_builder.dart' show kDataTableRootPath;
import 'datatable_file.dart';
import 'datatable_parser.dart';
import 'name_table_extender.dart';

/// New Release DataTable: a single asset under [kDataTableRootPath] holding
/// only custom rows (no base-game rows preserved).  Row layout differs from
/// the genre DataTables (55 bytes vs 71/72/73), so this builder does not
/// share `DataTableBuilder`'s row pipeline — only the [NameTableExtender]
/// (which is format-agnostic) and the uasset half of `DataTableParser` are
/// reused.  The uexp half of the parser is genre-specific (scans for
/// `T_Sub_`, expects 71/72/73-byte rows) and would mis-detect on NR — its
/// output is intentionally discarded; we re-detect ROW_START NR-style.
///
/// Pure port of `build_newrelease_datatable` (RR_VHS_Tool.py:4112-4383).
const String _dtName = 'NewRelease_Details_-_Data';

/// Each NR row is exactly 55 bytes since the v1.8.2 3-digit migration —
/// the BackgroundImage FString grew from 13 chars (`T_New_XXX_NN\0`) to
/// 14 (`T_New_XXX_NNN\0`), shifting every field after it by +1.  Base
/// game rows still use the old 54-byte (2-digit) layout, so we never
/// copy them as a template — we build each row from scratch.
const int _rowSize = 55;
const int _biLen = 14; // BackgroundImage FString incl trailing NUL.

// Field offsets within a 55-byte row — v1.8.2 layout (Python lines 4148-4155).
const int _biOffset = 27;            // bkg_b start
const int _genreOff = _biOffset + _biLen; // 41
const int _layoutOff = _genreOff + 1;     // 42 (int32)
const int _skuOff = _layoutOff + 4;       // 46 (uint16) + 2 pad
const int _ntuOff = _skuOff + 4;          // 50 (uint8)  — after SKU + pad
const int _nextKeyOff = _ntuOff + 1;      // 51 (uint32)

/// RK_NUM constant present in every row at offset 4 (Python Z. 3675).
/// Mirrors the per-row "RowKey number" Unreal stores alongside the FName.
const int _rkNum = 0x01A81780;

/// 8-byte uexp tail Unreal accepts when the engine should rebuild the TMap
/// hash on load (RR_VHS_Tool.py:3696, also used by genre DT builder).
const List<int> _plainFooter = [
  0x00, 0x00, 0x00, 0x00, 0xC1, 0x83, 0x2A, 0x9E
];

class NewReleaseBuildResult {
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final int rowCount;
  final List<String> warnings;

  const NewReleaseBuildResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.rowCount,
    this.warnings = const [],
  });
}

class NewReleaseBuildError implements Exception {
  final String code; // E004 / E011 / E015
  final String message;
  const NewReleaseBuildError(this.code, this.message);
  @override
  String toString() => '[$code] NewRelease DT build failed: $message';
}

class NewReleaseDataTableBuilder {
  final PakCache pakCache;
  NewReleaseDataTableBuilder(this.pakCache);

  /// Build the NR DataTable byte pair for [slots]. Returns null when there
  /// is nothing to ship (no valid slots after filtering); the pak builder
  /// can then skip emitting the file entirely.
  ///
  /// Filtering matches Python (Z. 3838-3845): drop slots whose genre isn't
  /// in [kNrGenreByte].  Romance/Western remain in the table because Python
  /// keeps them — they reference a non-existent `T_New_Rom_NN` texture, which
  /// degrades silently in-game.  The UI prevents this case by hiding those
  /// genres from the Add NR dialog.
  Future<NewReleaseBuildResult?> build(
    AppConfig config,
    List<NewReleaseSlot> slots,
  ) async {
    final warnings = <String>[];
    final valid = <NewReleaseSlot>[];
    for (final s in slots) {
      if (!kNrGenreByte.containsKey(s.genre)) {
        warnings.add(
            "Skipping NR '${s.title}' — genre '${s.genre}' not supported");
        continue;
      }
      valid.add(s);
    }
    if (valid.isEmpty) return null;

    // 1) Extract base files via PakCache — same path the genre DT builder
    // uses, except this asset's filename is fixed.
    final uaPath = '$kDataTableRootPath/$_dtName.uasset';
    final uePath = '$kDataTableRootPath/$_dtName.uexp';
    final uaRes = await pakCache.extractFile(config, uaPath);
    final ueRes = await pakCache.extractFile(config, uePath);
    if (!uaRes.ok || !ueRes.ok) {
      throw NewReleaseBuildError(
          'E011',
          'extract failed: uasset=${uaRes.warning}, uexp=${ueRes.warning}');
    }
    final uaBytes = await pakCache.readFile(config, uaPath);
    final ueBytes = await pakCache.readFile(config, uePath);
    if (uaBytes == null || ueBytes == null) {
      throw const NewReleaseBuildError(
          'E011', 'read failed after extract');
    }

    // 2) Parse the uasset half. We pass the NR DT name so the parser's
    // package-name sanity check matches; the uexp half of the parser is
    // discarded (NR row layout doesn't match its 71/72/73 detection).
    final parsed = _parseOrThrow(uaBytes, ueBytes);

    // 3) NR-specific ROW_START detection (Python Z. 3756-3760).
    final int rowStart;
    try {
      rowStart = _detectRowStart(ueBytes);
    } catch (e) {
      throw NewReleaseBuildError('E015', 'ROW_START detect: $e');
    }
    final rowCountOff = rowStart == 0x1A ? 0x12 : 0x0E;

    // 4) No template needed — the v1.8.2 (3-digit) row format is 55
    //    bytes, but base game rows still use the 54-byte 2-digit layout.
    //    Copying the base row would mis-align every field past the
    //    bkg_tex string.  Build each row from scratch instead (Python:
    //    `row = bytearray(ROW_SIZE)`, RR_VHS_Tool.py:4320).

    // 5) Extend the FName table with the row keys "1".."N" and the unique
    // movie titles.  indexOf is idempotent — adding a name that's already
    // present is a no-op.  Python adds row keys before titles (Z. 3779-3795)
    // so the final FName index ordering stays deterministic.
    final extender = NameTableExtender(parsed.uasset);
    for (var i = 0; i < valid.length; i++) {
      extender.indexOf((i + 1).toString());
    }
    for (final s in valid) {
      extender.indexOf(s.title);
    }

    // 6) Synthesise rows.  Linked list: row i's NextRowKey points at the
    // FName index of "(i+2)" (i.e. the next row's key string).  Last row
    // terminates the list with 0 (Python Z. 3877-3884).
    final rowsBuf = BytesBuilder();
    for (var i = 0; i < valid.length; i++) {
      final row = _buildRow(
        slot: valid[i],
        rowIndex: i,
        isLast: i == valid.length - 1,
        rowKeyIdx: extender.indexOf((i + 1).toString()),
        productNameIdx: extender.indexOf(valid[i].title),
        nextRowKeyIdx: i == valid.length - 1
            ? 0
            : extender.indexOf((i + 2).toString()),
      );
      rowsBuf.add(row);
    }

    // 7) Assemble new uexp: header (with patched row count) + rows + footer.
    final headerLen = rowStart;
    final newUexp = Uint8List(
        headerLen + valid.length * _rowSize + _plainFooter.length);
    newUexp.setRange(0, headerLen, ueBytes);
    final newView = ByteData.sublistView(newUexp);
    if (valid.length > 0xFFFF) {
      throw const NewReleaseBuildError(
          'E004', 'NR row count overflows uint16');
    }
    newView.setUint16(rowCountOff, valid.length, Endian.little);
    final rowBlock = rowsBuf.takeBytes();
    newUexp.setRange(headerLen, headerLen + rowBlock.length, rowBlock);
    newUexp.setRange(
        headerLen + rowBlock.length, newUexp.length, _plainFooter);

    // 8) Build new uasset and patch serial_size value.
    //    serial_size = rowStart + n_rows * _rowSize - 4 (Python Z. 4362).
    final newUasset = Uint8List.fromList(extender.buildUAssetBytes());
    final newSerialValue = rowStart + valid.length * _rowSize - 4;
    final newSerialOff = parsed.uasset.serialSizeOffset + extender.growthBytes;
    if (newSerialOff + 16 > newUasset.length) {
      throw const NewReleaseBuildError(
          'E005', 'serial_size offset out of bounds');
    }
    final uaView = ByteData.sublistView(newUasset);
    uaView.setInt64(newSerialOff, newSerialValue, Endian.little);
    uaView.setInt64(newSerialOff + 8, newUasset.length, Endian.little);

    return NewReleaseBuildResult(
      uassetBytes: newUasset,
      uexpBytes: newUexp,
      rowCount: valid.length,
      warnings: warnings,
    );
  }

  /// Synthesise one 55-byte NR row.  Layout from Python Z. 4122-4137 (v1.8.2):
  /// ```
  /// [0:4]   RowKey FName idx
  /// [4:8]   RK_NUM (0x01A81780)
  /// [8:12]  ProductName FName idx
  /// [12:16] ProductName FName num (0)
  /// [16:20] SubjectImage FString len (3)
  /// [20:23] "-1\0"
  /// [23:27] BackgroundImage FString len (14)
  /// [27:41] "T_New_XXX_NNN\0"  (3-digit slot number — v1.8.2 migration)
  /// [41]    Genre enum byte
  /// [42:46] LayoutStyle int32 (-1)
  /// [46:48] SKU uint16
  /// [48:50] padding (0x00 0x00)
  /// [50]    NewToUnlock byte (0x01)
  /// [51:55] NextRowKey idx (0 = end of linked list)
  /// ```
  static Uint8List _buildRow({
    required NewReleaseSlot slot,
    required int rowIndex,
    required bool isLast,
    required int rowKeyIdx,
    required int productNameIdx,
    required int nextRowKeyIdx,
  }) {
    // Zero-init: pad bytes [48..50) and the unused upper SKU bytes are
    // already 0; we only set fields that carry data.
    final row = Uint8List(_rowSize);
    final view = ByteData.sublistView(row);

    view.setUint32(0, rowKeyIdx, Endian.little);
    view.setUint32(4, _rkNum, Endian.little);
    view.setUint32(8, productNameIdx, Endian.little);
    view.setUint32(12, 0, Endian.little);

    // SubjectImage FString "-1\0"
    view.setInt32(16, 3, Endian.little);
    row[20] = 0x2D; // '-'
    row[21] = 0x31; // '1'
    row[22] = 0x00;

    // BackgroundImage FString "T_New_XXX_NNN\0" (13 chars + NUL = 14 bytes)
    final bkg = utf8.encode(slot.bkgTex);
    if (bkg.length != _biLen - 1) {
      throw NewReleaseBuildError('E004',
          'bkg_tex must be exactly ${_biLen - 1} chars (3-digit format), '
          'got "${slot.bkgTex}" (${bkg.length} bytes)');
    }
    view.setInt32(23, _biLen, Endian.little);
    row.setRange(_biOffset, _biOffset + bkg.length, bkg);
    row[_biOffset + bkg.length] = 0x00;

    row[_genreOff] = slot.genreByte;
    view.setInt32(_layoutOff, -1, Endian.little);

    // SKU uint16 — Python uses 5-digit values in 50000..59999 which fit
    // exactly in uint16 (max 65535).  A larger value would silently
    // truncate, so guard.
    if (slot.sku < 0 || slot.sku > 0xFFFF) {
      throw NewReleaseBuildError(
          'E004', 'SKU ${slot.sku} does not fit in uint16');
    }
    view.setUint16(_skuOff, slot.sku, Endian.little);
    // Bytes [_skuOff+2, _skuOff+4) are pad — left at 0 from Uint8List init.

    row[_ntuOff] = 0x01; // NewToUnlock = true
    view.setUint32(_nextKeyOff, isLast ? 0 : nextRowKeyIdx, Endian.little);

    return row;
  }

  static DataTableFile _parseOrThrow(Uint8List uaBytes, Uint8List ueBytes) {
    try {
      return DataTableParser.parsePair(
        uassetBytes: uaBytes,
        uexpBytes: ueBytes,
        genreDataTableName: _dtName,
      );
    } on DataTableParseError catch (e) {
      throw NewReleaseBuildError('E015', 'uasset parse: ${e.message}');
    }
  }

  /// Walk uexp positions 0x10..0x30 looking for the SubjectImage FString
  /// signature `len=3 + "-1\0"` that opens every row.  Mirrors Python
  /// Z. 3756-3760.
  static int _detectRowStart(Uint8List ue) {
    final view = ByteData.sublistView(ue);
    final scanEnd = ue.length < 0x30 ? ue.length - 23 : 0x30 - 1;
    for (var scan = 0x10; scan <= scanEnd; scan++) {
      if (scan + 23 > ue.length) break;
      final siLen = view.getInt32(scan + 16, Endian.little);
      if (siLen == 3 &&
          ue[scan + 20] == 0x2D &&
          ue[scan + 21] == 0x31 &&
          ue[scan + 22] == 0x00) {
        return scan;
      }
    }
    throw const NewReleaseBuildError(
        'E015', 'could not locate row start in NR uexp');
  }
}
