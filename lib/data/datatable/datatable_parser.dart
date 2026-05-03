import 'dart:convert';
import 'dart:typed_data';

import 'datatable_file.dart';

/// Read-only parser for Unreal Engine 4 DataTable files.
///
/// Ports the parsing fragments of `CleanDataTableBuilder._ensure_base_loaded`,
/// `_parse_name_table`, `_find_serial_offset`, and `_detect_uexp_layout` from
/// RR_VHS_Tool.py:2873-3089. Mutation/synthesis is deferred to slice 2c-B+.
///
/// Throws [DataTableParseError] on structurally invalid input. The thrown
/// message is intentionally specific (which field, which offset, what we
/// expected vs. what we read) — these errors should be loud, not silent,
/// because they typically mean the game file was patched or the asset is
/// not actually a DataTable.
class DataTableParseError implements Exception {
  final String message;
  const DataTableParseError(this.message);
  @override
  String toString() => 'DataTableParseError: $message';
}

class DataTableParser {
  /// Parse a uasset+uexp pair. The two halves come together because uasset's
  /// `serial_size` field is found by scanning for the value `len(uexp) - 4`
  /// (matching Python's `_find_serial_offset`).
  static DataTableFile parsePair({
    required Uint8List uassetBytes,
    required Uint8List uexpBytes,
    required String genreDataTableName,
  }) {
    final uasset =
        _parseUAsset(uassetBytes, uexpBytes, genreDataTableName);
    final uexp = _parseUExp(uexpBytes);
    return DataTableFile(uasset: uasset, uexp: uexp);
  }

  // ───────────────────────────────────────────────────────────── uasset

  static UAsset _parseUAsset(
      Uint8List ua, Uint8List uexp, String genreDtName) {
    if (ua.length < 0x40) {
      throw DataTableParseError(
          'uasset too small (${ua.length} bytes) — not a UE4 package');
    }
    final view = ByteData.sublistView(ua);
    final magic = view.getUint32(0, Endian.little);
    if (magic != UAsset.ue4Magic) {
      throw DataTableParseError(
          'UE4 magic mismatch: got 0x${magic.toRadixString(16)}, '
          'expected 0x${UAsset.ue4Magic.toRadixString(16)}');
    }

    // PackageName FString at 0x20: int32 length (incl. trailing null), then
    // UTF-8 bytes. plen IS the byte length of (string + null), per Unreal's
    // FString convention. Python reads it raw and rstrips the null.
    const plenOff = 0x20;
    final plen = view.getInt32(plenOff, Endian.little);
    if (plen <= 0 || plen > 300) {
      throw DataTableParseError(
          'PackageName length out of range: $plen at offset 0x$plenOff');
    }
    final pnameBytesEnd = 0x24 + plen;
    if (pnameBytesEnd > ua.length) {
      throw DataTableParseError(
          'PackageName FString runs off the end of the file');
    }
    // Strip trailing nulls. Python uses .rstrip("\x00") on the decoded text;
    // we do the same.
    final pnameRaw = utf8.decode(
      ua.sublist(0x24, pnameBytesEnd),
      allowMalformed: true,
    );
    final packageName = _rstripNulls(pnameRaw);

    // Sanity: the parsed package name must mention the genre. Mirrors the
    // Python check at line 2925.
    final genrePart = genreDtName.replaceAll('-', '');
    if (!(packageName.contains(genreDtName) ||
        packageName.contains(genrePart))) {
      throw DataTableParseError(
          'PackageName "$packageName" does not match expected genre '
          '"$genreDtName"');
    }

    // FSE = "field section end" of the PackageName FString. Subsequent header
    // fields are sequential from here:
    //   +4  name_count    (int32)
    //   +8  name_offset   (int32)
    //   +32 export_offset (int32)
    final fse = pnameBytesEnd;
    final nameCount = view.getInt32(fse + 4, Endian.little);
    final nameOffset = view.getInt32(fse + 8, Endian.little);
    final exportOffset = view.getInt32(fse + 32, Endian.little);
    if (!(nameCount > 0 &&
        nameOffset > 0 &&
        exportOffset > nameOffset &&
        exportOffset < ua.length)) {
      throw DataTableParseError(
          'Header sanity check failed: nameCount=$nameCount, '
          'nameOffset=$nameOffset, exportOffset=$exportOffset, '
          'fileSize=${ua.length}');
    }

    final nameTable = _parseNameTable(ua, nameOffset, nameCount);

    // serial_size lives at a canonical offset inside the first export entry:
    // exportOffset + 28 (RR_VHS_Tool.py:3627). The python code also has a
    // scan-for-value heuristic but that only works for the base-game flavour
    // where serial_size happens to equal len(uexp) - 4; the builder writes
    // a different formula (rowStart + rows - 4, excluding the 8-byte
    // PLAIN_FOOTER) so the heuristic mis-fires on our own output. The
    // structural offset works for both.
    final serialOff = exportOffset + 28;
    if (serialOff + 8 > ua.length) {
      throw DataTableParseError(
          'serial_size field offset $serialOff out of uasset bounds '
          '(${ua.length})');
    }
    final serialSize =
        ByteData.sublistView(ua).getInt64(serialOff, Endian.little);

    return UAsset(
      rawBytes: ua,
      packageName: packageName,
      packageNameLengthOffset: plenOff,
      packageSummaryOffset: fse,
      nameCount: nameCount,
      nameOffset: nameOffset,
      exportOffset: exportOffset,
      serialSizeOffset: serialOff,
      serialSize: serialSize,
      nameTable: nameTable,
    );
  }

  static NameTable _parseNameTable(Uint8List ua, int start, int count) {
    final entries = <NameTableEntry>[];
    var i = start;
    final view = ByteData.sublistView(ua);
    for (var n = 0; n < count; n++) {
      if (i + 4 > ua.length) {
        throw DataTableParseError(
            'Name table truncated at entry $n/$count (offset $i)');
      }
      final length = view.getInt32(i, Endian.little);
      if (length < 1 || length > 300) {
        throw DataTableParseError(
            'Name table entry $n has implausible length $length at $i');
      }
      final end = i + 4 + length;
      if (end + 4 > ua.length) {
        throw DataTableParseError(
            'Name table entry $n string + flags overruns file at $i');
      }
      final raw = ua.sublist(i + 4, end);
      if (raw.isEmpty || raw.last != 0x00) {
        throw DataTableParseError(
            'Name table entry $n missing trailing null at $i '
            '(length=$length, last=0x${raw.lastOrZero.toRadixString(16)})');
      }
      final value = utf8.decode(raw.sublist(0, raw.length - 1));
      final flags = view.getUint32(end, Endian.little);
      entries.add(NameTableEntry(value, flags));
      i = end + 4;
    }
    return NameTable(entries: entries, regionStart: start, regionEnd: i);
  }

  // ───────────────────────────────────────────────────────────────── uexp

  static UExp _parseUExp(Uint8List ue) {
    if (ue.length < 0x18) {
      throw DataTableParseError('uexp too small (${ue.length} bytes)');
    }

    // Locate ROW_START via the first occurrence of "T_Sub_" (start search at
    // 4 to skip any header-internal coincidence). The T_Sub FString is always
    // at byte 20 within a row; subtract to find row start. Python:3028.
    const tSubOffsetWithinRow = 20;
    final pos = _indexOfBytes(ue, _tSub, 4);
    var rowStart = pos < 0 ? 0x16 : pos - tSubOffsetWithinRow;
    if (rowStart < 0) rowStart = 0x16;

    // row_count_off is deterministic from rowStart (Python:3041-3044).
    final rowCountOff = (rowStart == 0x1A) ? 0x12 : 0x0E;
    final view = ByteData.sublistView(ue);
    final rowCount = view.getUint16(rowCountOff, Endian.little);

    // RK_NUM lives at row_start+4 in every row. Detected from the first row.
    final rowKeyNumber =
        rowStart + 8 <= ue.length ? view.getUint32(rowStart + 4, Endian.little) : 0;

    // Detect row size deterministically by elimination. Only 71/72/73 are
    // legal sizes (RowSchema variants); rowCount is authoritative; the file
    // ends with at least an 8-byte tail (PLAIN_FOOTER for builder output, a
    // larger TMap blob for base-game files). So a candidate size is valid
    // only if `rowStart + rowCount*size + 8 <= file_size`. When multiple
    // candidates fit, we cross-check by reading RK_NUM at several row
    // positions — they must all match the value detected in row 0.
    final detectedSize = _detectRowSize(ue, rowStart, rowKeyNumber);
    final schema = RowSchema.fromSize(detectedSize);

    // Genre/placement bytes from first parseable row. Mirrors Python
    // `_build_si_templates` (RR_VHS_Tool.py:3119-3139). Defaults if none
    // of the first 30 rows looks well-formed.
    final templ = _detectRowTemplate(ue, rowStart, detectedSize, rowCount);

    return UExp(
      rawBytes: ue,
      rowStart: rowStart,
      rowCountOffset: rowCountOff,
      rowCount: rowCount,
      rowSize: detectedSize,
      schema: schema,
      rowKeyNumber: rowKeyNumber,
      genreByte: templ.$1,
      placementByte: templ.$2,
    );
  }

  /// Walks up to 30 rows looking for one with sensible SI/BI lengths, then
  /// extracts the genre and placement bytes from `after_bi+8` and `+9`.
  static (int genre, int placement) _detectRowTemplate(
      Uint8List ue, int rowStart, int rowSize, int rowCount) {
    final view = ByteData.sublistView(ue);
    final probe = rowCount > 30 ? 30 : rowCount;
    for (var n = 0; n < probe; n++) {
      final off = rowStart + n * rowSize;
      if (off + 20 > ue.length) break;
      final siLen = view.getInt32(off + 16, Endian.little);
      if (siLen < 7 || siLen > 12) continue;
      final biOff = off + 20 + siLen;
      if (biOff + 4 > ue.length) continue;
      final biLen = view.getInt32(biOff, Endian.little);
      if (biLen < 8 || biLen > 20) continue;
      final afterBi = biOff + 4 + biLen;
      if (afterBi + 10 > ue.length) continue;
      return (ue[afterBi + 8], ue[afterBi + 9]);
    }
    return (4, 1); // Horror defaults — Python uses these as fallback.
  }

  static int _detectRowSize(Uint8List ue, int rowStart, int rk) {
    // Detect by RK_NUM probing only: do NOT use the header's rowCount as a
    // file-size constraint. Action's base-game uexp has rowCount=1155 in
    // the header but only ~1152 actual 72-byte rows fit — Python's walker
    // ignores the header count too (RR_VHS_Tool.py:3296 advances by row_size
    // until validation fails). Probe each candidate size; the correct one
    // has RK_NUM at row+4 for several consecutive rows.
    //
    // Probe count is dynamic: small builder-output files (1 slot + sentinel
    // = 2 rows) only fit 2 probes, so we adapt rather than refuse.
    final view = ByteData.sublistView(ue);
    for (final size in const [71, 72, 73]) {
      final maxProbes = ((ue.length - rowStart) ~/ size).clamp(1, 6);
      var ok = true;
      for (var n = 0; n < maxProbes; n++) {
        final off = rowStart + n * size + 4;
        if (off + 4 > ue.length) {
          ok = false;
          break;
        }
        if (view.getUint32(off, Endian.little) != rk) {
          ok = false;
          break;
        }
      }
      if (ok) return size;
    }
    return 72; // V2 fallback — most common in base game.
  }

  // ────────────────────────────────────────────────────────────── helpers

  static int _indexOfBytes(Uint8List haystack, List<int> needle, int from) {
    if (needle.isEmpty) return from;
    final last = haystack.length - needle.length;
    for (var i = from; i <= last; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  static String _rstripNulls(String s) {
    var n = s.length;
    while (n > 0 && s.codeUnitAt(n - 1) == 0) {
      n--;
    }
    return s.substring(0, n);
  }
}

const List<int> _tSub = [0x54, 0x5F, 0x53, 0x75, 0x62, 0x5F]; // "T_Sub_"

extension on Uint8List {
  int get lastOrZero => isEmpty ? 0 : last;
}
