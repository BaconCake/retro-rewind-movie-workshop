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
/// the genre DataTables (54 bytes vs 71/72/73), so this builder does not
/// share `DataTableBuilder`'s row pipeline — only the [NameTableExtender]
/// (which is format-agnostic) and the uasset half of `DataTableParser` are
/// reused.  The uexp half of the parser is genre-specific (scans for
/// `T_Sub_`, expects 71/72/73-byte rows) and would mis-detect on NR — its
/// output is intentionally discarded; we re-detect ROW_START NR-style.
///
/// Pure port of `build_newrelease_datatable` (RR_VHS_Tool.py:3663-3917).
const String _dtName = 'NewRelease_Details_-_Data';

/// Each NR row is exactly 54 bytes — the BackgroundImage FString is fixed at
/// 13 chars (`T_New_XXX_NN\0`), which is why the UI caps NR count per genre
/// at 99 (3-digit names would widen the row).  See [kNrPerGenreCap].
const int _rowSize = 54;

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

    // 4) Take the first base row as a template — this preserves any
    // engine-internal padding bytes between explicit fields and matches
    // Python's approach (Z. 3771).
    if (rowStart + _rowSize > ueBytes.length) {
      throw const NewReleaseBuildError(
          'E015', 'base uexp too short to read template row');
    }
    final tmpl = ueBytes.sublist(rowStart, rowStart + _rowSize);

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
        template: tmpl,
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
    //    serial_size = rowStart + n_rows*54 - 4 (Python Z. 3895-3905).
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

  /// Synthesise one 54-byte NR row.  Layout from Python Z. 3673-3690:
  /// ```
  /// [0:4]   RowKey FName idx
  /// [4:8]   RK_NUM (0x01A81780)
  /// [8:12]  ProductName FName idx
  /// [12:16] ProductName FName num (0)
  /// [16:20] SubjectImage FString len (3)
  /// [20:23] "-1\0"
  /// [23:27] BackgroundImage FString len (13)
  /// [27:40] "T_New_XXX_NN\0"
  /// [40]    Genre enum byte
  /// [41:45] LayoutStyle int32 (-1)
  /// [45:47] SKU uint16
  /// [47]    0x00
  /// [48]    0x00
  /// [49]    NewToUnlock byte (0x01)
  /// [50:54] NextRowKey idx (0 = end of linked list)
  /// ```
  static Uint8List _buildRow({
    required NewReleaseSlot slot,
    required int rowIndex,
    required bool isLast,
    required Uint8List template,
    required int rowKeyIdx,
    required int productNameIdx,
    required int nextRowKeyIdx,
  }) {
    final row = Uint8List.fromList(template);
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

    // BackgroundImage FString "T_New_XXX_NN\0"
    final bkg = utf8.encode(slot.bkgTex);
    if (bkg.length != 12) {
      throw NewReleaseBuildError('E004',
          'bkg_tex must be exactly 12 chars, got "${slot.bkgTex}" '
          '(${bkg.length} bytes)');
    }
    view.setInt32(23, 13, Endian.little);
    row.setRange(27, 39, bkg);
    row[39] = 0x00;

    row[40] = slot.genreByte;
    view.setInt32(41, -1, Endian.little);

    // SKU uint16 — Python uses 5-digit values in 50000..59999 which fit
    // exactly in uint16 (max 65535).  A larger value would silently
    // truncate, so guard.
    if (slot.sku < 0 || slot.sku > 0xFFFF) {
      throw NewReleaseBuildError(
          'E004', 'SKU ${slot.sku} does not fit in uint16');
    }
    view.setUint16(45, slot.sku, Endian.little);

    row[47] = 0x00;
    row[48] = 0x00;
    row[49] = 0x01; // NewToUnlock = true
    view.setUint32(50, isLast ? 0 : nextRowKeyIdx, Endian.little);

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
