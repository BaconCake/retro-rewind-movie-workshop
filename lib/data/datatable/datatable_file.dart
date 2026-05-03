import 'dart:convert';
import 'dart:typed_data';

/// One entry in an Unreal `FName` table: a UTF-8 string plus a 4-byte trailing
/// flags word. On disk an entry is `int32 length | UTF-8 bytes (incl. \x00) |
/// uint32 flags`. The string is referenced from rows by *index* into this
/// table, never by value.
class NameTableEntry {
  final String value;
  final int flags;

  const NameTableEntry(this.value, this.flags);
}

/// The FName table region of a `.uasset` file.
///
/// Tracks the original on-disk byte range [regionStart, regionEnd) so the
/// caller can verify a parse-then-serialize roundtrip is byte-perfect.
class NameTable {
  final List<NameTableEntry> entries;
  final int regionStart;
  final int regionEnd;

  const NameTable({
    required this.entries,
    required this.regionStart,
    required this.regionEnd,
  });

  int get length => entries.length;

  /// Serialise the table back to bytes. Used by 2c-B to rebuild a name table
  /// after appending entries; in 2c-A this gives us the parser's roundtrip
  /// test against the original byte slice.
  Uint8List toBytes() {
    final builder = BytesBuilder(copy: false);
    for (final e in entries) {
      final s = utf8.encode(e.value);
      final lenWithNull = s.length + 1;
      final hdr = ByteData(4)..setInt32(0, lenWithNull, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      builder.add(s);
      builder.addByte(0x00);
      final flags = ByteData(4)..setUint32(0, e.flags, Endian.little);
      builder.add(flags.buffer.asUint8List());
    }
    return builder.toBytes();
  }
}

/// Parsed view of a `.uasset` file.
///
/// `rawBytes` holds the unmodified file contents — slices are exposed through
/// region offsets so 2c-B (name table extension) and 2c-D (serial_size patch)
/// can re-emit the file without re-parsing the bits they don't touch.
class UAsset {
  /// The UE4 package magic at file offset 0.
  static const int ue4Magic = 0x9E2A83C1;

  final Uint8List rawBytes;
  final String packageName;
  final int packageNameLengthOffset; // int32 at this offset = packageName len + 1 (incl. null)
  final int packageSummaryOffset; // == 0x24 + plen ("FSE" in Python)
  final int nameCount;
  final int nameOffset;
  final int exportOffset;
  final int serialSizeOffset; // byte offset of the int64 serial_size field
  final int serialSize;
  final NameTable nameTable;

  const UAsset({
    required this.rawBytes,
    required this.packageName,
    required this.packageNameLengthOffset,
    required this.packageSummaryOffset,
    required this.nameCount,
    required this.nameOffset,
    required this.exportOffset,
    required this.serialSizeOffset,
    required this.serialSize,
    required this.nameTable,
  });
}

/// Which row layout the genre's uexp uses. Row size in bytes is given by [size].
///
/// Variants confirmed in Python source (see RR_VHS_Tool.py:~3055):
///   v1 — 71 bytes (Western, Adventure: no Placement, no ColorPalette)
///   v2 — 72 bytes (standard: Placement yes, no ColorPalette)
///   v3 — 73 bytes (Police: Placement yes, ColorPalette yes)
enum RowSchema {
  v1(71),
  v2(72),
  v3(73);

  final int size;
  const RowSchema(this.size);

  static RowSchema fromSize(int size) {
    switch (size) {
      case 71:
        return RowSchema.v1;
      case 72:
        return RowSchema.v2;
      case 73:
        return RowSchema.v3;
    }
    throw ArgumentError('Unrecognised row size: $size (expected 71/72/73)');
  }
}

/// Parsed view of a `.uexp` file (DataTable row data).
///
/// On disk a uexp is laid out as:
///
///     [header]      rowStart bytes (22 for 0x16 layout, 26 for 0x1A)
///     [rows]        rowCount × rowSize bytes
///     [tail]        variable: TMap hash index in base-game files,
///                   or just the 8-byte PLAIN_FOOTER in builder output
///
/// The base-game tail and the builder tail differ — the engine rebuilds the
/// TMap from PLAIN_FOOTER on load when the row count changed (see
/// RR_VHS_Tool.py:3409). Slice 2c-A keeps the original tail bytes around so a
/// roundtrip of an unmodified file stays byte-perfect; 2c-D replaces them
/// with PLAIN_FOOTER whenever it emits a new uexp.
class UExp {
  /// 8-byte tail magic that the *builder* writes after rows. Base-game files
  /// have a longer trailer (full TMap hash) ending in different bytes.
  static final Uint8List plainFooter =
      Uint8List.fromList(const [0x00, 0x00, 0x00, 0x00, 0xC1, 0x83, 0x2A, 0x9E]);

  final Uint8List rawBytes;

  /// First byte of row data. 0x16 for a 22-byte header, 0x1A for a 26-byte header.
  final int rowStart;

  /// Offset of the row count uint16 field inside the header.
  /// 0x0E for ROW_START=0x16, 0x12 for ROW_START=0x1A.
  final int rowCountOffset;

  /// Row count as stored in the header field. Authoritative — the engine
  /// trusts this, not any value derived from file size.
  final int rowCount;

  /// Detected per-row size (matches a known [RowSchema]).
  final int rowSize;
  final RowSchema schema;

  /// Detected RowKey FName *number* (the int32 stored alongside the FName
  /// index in row bytes [4..8)). Varies per genre (Horror 0x05001780,
  /// Western 0x05201780, Police 0x04001780, …).
  final int rowKeyNumber;

  /// Genre byte read from `uexp[after_bi + 8]` of the first parseable row.
  /// Same value for every row in a given genre — Horror is 0x04, etc.
  /// Used by the row synthesizer to write the same byte into new rows.
  final int genreByte;

  /// Placement byte read from `uexp[after_bi + 9]` of the first parseable row.
  /// Only meaningful for [RowSchema.v2] and [RowSchema.v3]; on V1 files this
  /// position holds the low byte of LayoutStyle, so the value is set but
  /// unused.
  final int placementByte;

  const UExp({
    required this.rawBytes,
    required this.rowStart,
    required this.rowCountOffset,
    required this.rowCount,
    required this.rowSize,
    required this.schema,
    required this.rowKeyNumber,
    required this.genreByte,
    required this.placementByte,
  });

  /// First byte after the row block — equivalent to Python's `len(uexp_header) +
  /// total_rows * row_size`. The bytes from here to `rawBytes.length` are the
  /// trailer (TMap hash + magic for base-game files; PLAIN_FOOTER for builder).
  int get rowsEndOffset => rowStart + rowCount * rowSize;

  /// Slice the bytes of row [n] (0-indexed).
  Uint8List rowAt(int n) {
    final off = rowStart + n * rowSize;
    return Uint8List.sublistView(rawBytes, off, off + rowSize);
  }

  /// Bytes after the row block. Length varies between base-game files (large
  /// pre-computed TMap) and builder output (just the 8-byte PLAIN_FOOTER).
  Uint8List get tailBytes =>
      Uint8List.sublistView(rawBytes, rowsEndOffset);
}

/// A parsed DataTable, both halves of the on-disk pair.
class DataTableFile {
  final UAsset uasset;
  final UExp uexp;

  const DataTableFile({required this.uasset, required this.uexp});
}
