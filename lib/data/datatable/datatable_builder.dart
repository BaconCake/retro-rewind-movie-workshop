import 'dart:math';
import 'dart:typed_data';

import '../../domain/entities/app_config.dart';
import '../services/pak_cache.dart';
import 'datatable_file.dart';
import 'datatable_parser.dart';
import 'name_table_extender.dart';
import 'row_decoder.dart';
import 'row_synthesizer.dart';
import 'slot_data.dart';

/// Where the base game stores per-genre DataTables inside its pak. Used both
/// for extraction (PakCache) and for the destination layout in build_work.
const String kDataTableRootPath =
    'RetroRewind/Content/VideoStore/core/blueprint/data';

class DataTableBuildResult {
  final String dataTableName;
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final int slotCount;

  const DataTableBuildResult({
    required this.dataTableName,
    required this.uassetBytes,
    required this.uexpBytes,
    required this.slotCount,
  });
}

class DataTableBuildError implements Exception {
  final String code; // E004 / E005 / E011 / E015
  final String dataTableName;
  final String message;
  const DataTableBuildError(this.code, this.dataTableName, this.message);
  @override
  String toString() =>
      '[$code] DataTable build failed for $dataTableName: $message';
}

/// Full uasset+uexp build for a single genre. Mirrors `CleanDataTableBuilder.
/// build` (RR_VHS_Tool.py:3399-3631):
///
///   1. Pull the base-game uasset+uexp via PakCache.
///   2. Parse → decode existing slots into [SlotData] (or take a caller
///      override).
///   3. Apply title overrides.
///   4. Extend the FName table with row keys + new titles.
///   5. Synthesise rows + sentinel.
///   6. Splice the new uexp (header + rows + PLAIN_FOOTER, header rowCount
///      patched).
///   7. Patch the new uasset's serial_size value (= rowStart + len(rowBytes)
///      − 4) at the position the parser found, shifted by name-table growth.
///
/// The output is a pair of byte buffers; PakBuilder writes them under
/// `<workRoot>/$kDataTableRootPath/$genre.uasset|.uexp`.
class DataTableBuilder {
  final PakCache pakCache;
  final Random? _random;

  DataTableBuilder(this.pakCache, {Random? random}) : _random = random;

  /// PLAIN_FOOTER our builder appends to every emitted uexp. Engine rebuilds
  /// the TMap hash on load when row count changed (RR_VHS_Tool.py:3409).
  static final Uint8List _plainFooter = UExp.plainFooter;

  Future<DataTableBuildResult> build(
    AppConfig config,
    String dataTableName, {
    List<SlotData>? slotOverride,
    Map<String, String> titleOverrides = const {},
    Map<int, String> bkgTexPatches = const {},
  }) async {
    // 1) Extract base files.
    final uaRes = await pakCache.extractFile(
        config, '$kDataTableRootPath/$dataTableName.uasset');
    final ueRes = await pakCache.extractFile(
        config, '$kDataTableRootPath/$dataTableName.uexp');
    if (!uaRes.ok || !ueRes.ok) {
      throw DataTableBuildError('E011', dataTableName,
          'extract failed: uasset=${uaRes.warning}, uexp=${ueRes.warning}');
    }
    final uaBytes = await pakCache.readFile(
        config, '$kDataTableRootPath/$dataTableName.uasset');
    final ueBytes = await pakCache.readFile(
        config, '$kDataTableRootPath/$dataTableName.uexp');
    if (uaBytes == null || ueBytes == null) {
      throw DataTableBuildError(
          'E011', dataTableName, 'read failed after extract');
    }

    // 2) Parse + decode slots.
    final DataTableFile parsed;
    try {
      parsed = DataTableParser.parsePair(
        uassetBytes: uaBytes,
        uexpBytes: ueBytes,
        genreDataTableName: dataTableName,
      );
    } on DataTableParseError catch (e) {
      throw DataTableBuildError('E015', dataTableName, e.message);
    }
    final baseSlots = slotOverride ??
        RowDecoder.decodeBaseSlots(parsed.uexp, parsed.uasset.nameTable);
    if (baseSlots.isEmpty) {
      throw DataTableBuildError(
          'E004', dataTableName, 'no slots decoded from base uexp');
    }

    // Apply bkg-tex patches (e.g. swap a base-game 2-digit ref like
    // `T_Bkg_Dra_01` for a custom 3-digit ref `T_Bkg_Dra_001` so the rebuilt
    // DataTable points at a user-supplied texture).  Patch keys are 1-based
    // slot indices; out-of-range patches are silently dropped (the texture
    // file is still written but no row references it — that's the slice 3
    // limitation).  Adding new rows for out-of-range custom slots is slice 4
    // territory.
    final slots = bkgTexPatches.isEmpty
        ? baseSlots
        : List<SlotData>.generate(baseSlots.length, (i) {
            final patch = bkgTexPatches[i + 1];
            return patch == null
                ? baseSlots[i]
                : baseSlots[i].copyWith(bkgTex: patch);
          });

    // 3+4+5) Extend name table, synthesise rows.
    final extender = NameTableExtender(parsed.uasset);
    final synth = RowSynthesizer.fromBase(
      baseUexp: parsed.uexp,
      names: extender,
      random: _random,
    );
    final Uint8List rowBlock;
    try {
      rowBlock = synth.buildRows(slots, titleOverrides: titleOverrides);
    } catch (e) {
      throw DataTableBuildError(
          'E004', dataTableName, 'row synthesis threw: $e');
    }

    // 6) Assemble new uexp: header (with patched rowCount) + rows + footer.
    final headerLen = parsed.uexp.rowStart;
    final newUexpLen = headerLen + rowBlock.length + _plainFooter.length;
    final newUexp = Uint8List(newUexpLen)
      ..setRange(0, headerLen, parsed.uexp.rawBytes)
      ..setRange(headerLen, headerLen + rowBlock.length, rowBlock)
      ..setRange(headerLen + rowBlock.length, newUexpLen, _plainFooter);

    // Header rowCount field is uint16 LE at parsed.uexp.rowCountOffset.
    // Total rows = real slots + 1 sentinel.
    final totalRows = slots.length + 1;
    if (totalRows > 0xFFFF) {
      throw DataTableBuildError(
          'E004', dataTableName, 'row count $totalRows overflows uint16');
    }
    ByteData.sublistView(newUexp)
        .setUint16(parsed.uexp.rowCountOffset, totalRows, Endian.little);

    // 7) Build new uasset and patch serial_size value at shifted offset.
    final newUasset = Uint8List.fromList(extender.buildUAssetBytes());
    final newSerialOff =
        parsed.uasset.serialSizeOffset + extender.growthBytes;
    final newSerialValue = parsed.uexp.rowStart + rowBlock.length - 4;
    if (newSerialOff + 16 > newUasset.length) {
      throw DataTableBuildError('E005', dataTableName,
          'serial_size offset $newSerialOff out of bounds in '
          '${newUasset.length}-byte uasset');
    }
    final view = ByteData.sublistView(newUasset);
    view.setInt64(newSerialOff, newSerialValue, Endian.little);
    // The int64 immediately after serial_size stores SerialOffset (the file
    // position where uexp starts when concatenated). For standalone .uasset
    // pairs that's the uasset size. Python writes len(new_uasset) here
    // (RR_VHS_Tool.py:3630). Our extender already shifted any int64 ==
    // old_uasset_size to new_uasset_size, but if SerialOffset was different
    // (e.g. a stale value from base game), we override it here.
    view.setInt64(newSerialOff + 8, newUasset.length, Endian.little);

    return DataTableBuildResult(
      dataTableName: dataTableName,
      uassetBytes: newUasset,
      uexpBytes: newUexp,
      slotCount: slots.length,
    );
  }
}
