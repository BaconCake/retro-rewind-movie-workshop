import 'dart:convert';
import 'dart:typed_data';

import 'datatable_file.dart';
import 'datatable_parser.dart';

/// Builds a new `.uasset` whose FName table has been extended with additional
/// entries, while keeping every other byte of the original file structurally
/// valid.
///
/// Ports `CleanDataTableBuilder._extend_name_table` (RR_VHS_Tool.py:3310-3397).
/// The Python comment block at line 59 and 205-206 explains why the insertion
/// goes at the *end of the existing name table* rather than at `export_offset`:
/// there's a gap between the two containing import/depends/preload data, and
/// shifting that into the middle of the name table breaks the file.
///
/// Header fields touched on insert:
///
///   abs 0x1C        TotalHeaderSize       += shift
///   fse + 4         NameCount             += new entry count
///   fse + 88        NameCount (2nd copy)  += new entry count
///   fse + 8/16/32/40/44/136/160                              += shift if ≥ insertOff
///   somewhere after insert: int64 == old uasset size         → new uasset size
///
/// The `serial_size` field (whose value is `len(uexp)-4`) is intentionally
/// untouched — its value depends on the uexp side, not the uasset's own size.
class NameTableExtender {
  static const List<int> _fseOffsetFields = [8, 16, 32, 40, 44, 136, 160];
  static const int _totalHeaderSizeOff = 0x1C;
  static const int _secondNameCountOffsetFromFse = 88;

  final UAsset original;
  final List<NameTableEntry> _entries;
  final Map<String, int> _index;
  final int _originalEntryCount;

  NameTableExtender(this.original)
      : _entries = List<NameTableEntry>.from(original.nameTable.entries),
        _index = {
          for (var i = 0; i < original.nameTable.entries.length; i++)
            original.nameTable.entries[i].value: i,
        },
        _originalEntryCount = original.nameTable.entries.length;

  /// Returns the FName index for [value]. If not yet present, appends a new
  /// entry with [flags] and returns the new index.
  int indexOf(String value, {int flags = 0}) {
    final existing = _index[value];
    if (existing != null) return existing;
    final idx = _entries.length;
    _entries.add(NameTableEntry(value, flags));
    _index[value] = idx;
    return idx;
  }

  /// Looks up an FName index without inserting. Returns null if absent.
  int? find(String value) => _index[value];

  /// Number of entries appended since construction.
  int get newEntryCount => _entries.length - _originalEntryCount;

  /// Total uasset growth in bytes from the appended entries.
  int get growthBytes {
    var sum = 0;
    for (var i = _originalEntryCount; i < _entries.length; i++) {
      sum += _entrySize(_entries[i]);
    }
    return sum;
  }

  /// The full extended FName table. Useful when callers want to peek without
  /// committing to a uasset rebuild yet.
  List<NameTableEntry> get entries => List.unmodifiable(_entries);

  static int _entrySize(NameTableEntry e) {
    return 4 + utf8.encode(e.value).length + 1 + 4; // length | utf-8 | null | flags
  }

  /// Emit a fresh `.uasset` byte buffer containing the extended name table
  /// and all dependent header fields rewritten. When [newEntryCount] is zero,
  /// returns the original bytes verbatim (identity, no copy).
  Uint8List buildUAssetBytes() {
    if (newEntryCount == 0) return original.rawBytes;

    final old = original.rawBytes;
    final insertOff = original.nameTable.regionEnd;
    final shift = growthBytes;
    final newSize = old.length + shift;
    final newUa = Uint8List(newSize);

    // Splice: prefix | new entries | suffix.
    newUa.setRange(0, insertOff, old);
    final newEntries = _serialiseNewEntries();
    newUa.setRange(insertOff, insertOff + shift, newEntries);
    newUa.setRange(insertOff + shift, newSize, old, insertOff);

    final view = ByteData.sublistView(newUa);
    final fse = original.packageSummaryOffset;

    // 1) TotalHeaderSize at absolute 0x1C — bump by shift.
    final oldTotal = view.getInt32(_totalHeaderSizeOff, Endian.little);
    view.setInt32(_totalHeaderSizeOff, oldTotal + shift, Endian.little);

    // 2) NameCount at fse+4 and fse+88. These store *counts*, not offsets,
    // so the value bumps by newEntryCount, not by shift.
    final newCount = original.nameCount + newEntryCount;
    final ncOff1 = fse + 4;
    if (ncOff1 + 4 <= newSize) {
      view.setInt32(ncOff1, newCount, Endian.little);
    }
    final ncOff2 = fse + _secondNameCountOffsetFromFse;
    if (ncOff2 + 4 <= newSize) {
      view.setInt32(ncOff2, newCount, Endian.little);
    }

    // 3) FSE_OFFSET_FIELDS — int32 file-offsets that need += shift if their
    // value points at or after the insertion point in the OLD file.
    final oldSize = old.length;
    for (final rel in _fseOffsetFields) {
      final absOff = fse + rel;
      if (absOff + 4 > oldSize) continue;
      final oldVal = ByteData.sublistView(old).getInt32(absOff, Endian.little);
      if (oldVal >= insertOff && oldVal <= oldSize) {
        view.setInt32(absOff, oldVal + shift, Endian.little);
      }
    }

    // 4) Scan for any int64 == old uasset size after the insertion point and
    // replace with the new size. Step is 4 bytes (Unreal int64 alignment).
    // Mirrors the Python loop at RR_VHS_Tool.py:3391-3393.
    final scanStart = (insertOff + shift).clamp(0, newSize - 8);
    for (var i = scanStart; i + 8 <= newSize; i += 4) {
      if (view.getInt64(i, Endian.little) == oldSize) {
        view.setInt64(i, newSize, Endian.little);
      }
    }

    return newUa;
  }

  /// Convenience: build the bytes and re-parse them through [DataTableParser]
  /// so the caller gets a fully-typed [UAsset] view of the extended file.
  UAsset buildUAsset({required String genreDataTableName}) {
    final bytes = buildUAssetBytes();
    if (newEntryCount == 0) return original;
    // Parse the new uasset against a synthetic uexp size: the parser only
    // needs len(uexp) to find serial_size, and that value didn't change.
    final fakeUexpLen = original.serialSize + 4;
    final uexpStub = Uint8List(fakeUexpLen);
    final pair = DataTableParser.parsePair(
      uassetBytes: bytes,
      uexpBytes: uexpStub,
      genreDataTableName: genreDataTableName,
    );
    return pair.uasset;
  }

  Uint8List _serialiseNewEntries() {
    final builder = BytesBuilder(copy: false);
    for (var i = _originalEntryCount; i < _entries.length; i++) {
      final e = _entries[i];
      final s = utf8.encode(e.value);
      final hdr = ByteData(4)..setInt32(0, s.length + 1, Endian.little);
      builder.add(hdr.buffer.asUint8List());
      builder.add(s);
      builder.addByte(0x00);
      final flags = ByteData(4)..setUint32(0, e.flags, Endian.little);
      builder.add(flags.buffer.asUint8List());
    }
    return builder.toBytes();
  }
}
