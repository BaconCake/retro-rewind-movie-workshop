import 'dart:convert';
import 'dart:typed_data';

/// One substring substitution applied to every name-table entry that
/// contains [old].  When any substitution lands, the entry's FName hash
/// is zeroed so UE re-hashes from the patched string at load.
class NameTablePatch {
  final String old;
  final String replacement;
  const NameTablePatch(this.old, this.replacement);
}

/// Outcome of a uasset rebuild — patched bytes + diagnostic counters.
/// [totalShift] is `newLen - oldLen`; non-zero only when at least one
/// patch (PackageName or name-table) changed string length.
class UAssetRebuildResult {
  final Uint8List bytes;
  final int totalShift;
  final int patchedNames;
  const UAssetRebuildResult({
    required this.bytes,
    required this.totalShift,
    required this.patchedNames,
  });
}

class UAssetRebuildError implements Exception {
  final String message;
  const UAssetRebuildError(this.message);
  @override
  String toString() => 'UAssetRebuildError: $message';
}

/// Rebuild a uasset with a (potentially length-changing) PackageName and
/// substring substitutions applied to every name-table entry.
///
/// Pure port of `_rebuild_uasset_with_name_patches`
/// (RR_VHS_Tool.py:2158-2283).  Used by the standee MI builder and
/// blueprint cloner once Python switched NR slot numbering from 2-digit
/// to 3-digit (v1.8.2, commit `4a3a6ad`) — the new names grow strings by
/// one byte per occurrence, so the length-preserving `replaceAllSameLength`
/// path can no longer cover them.
///
/// What this function does:
///   1. Copies bytes `[0..0x20)` (uasset header up to PackageName length).
///   2. Writes the new PackageName length + UTF-8 bytes + NUL.
///   3. Copies the pre-name-table region `[fse..nameOffset)` verbatim.
///   4. Walks the name table; for each entry whose UTF-8 string contains
///      any patch's [old], substitutes with [replacement] and zeros the
///      4-byte FName hash that follows the entry.
///   5. Copies everything after the name table verbatim.
///   6. Bumps offset fields at `newFse + {16, 32, 40, 44, 136, 160, 176}`
///      by `totalShift` (only if currently > 0).
///   7. Re-points export[0].SerialOffset (an int64 at `newExportOff + 36`)
///      to the new file length.
///   8. For multi-export uassets (Blueprints), shifts every Export[i>0]
///      .SerialOffset by `totalShift`.  The export-record stride is
///      detected via probe-list `[96, 104, 100, 88, 112]` against the
///      original asset's expected `e0_off + e0_size` — if no probe
///      matches, the shift is skipped (rare, single-export assets only
///      need step 7 anyway).
///
/// Throws [UAssetRebuildError] when the input is too short or the
/// PackageName length / name offset values aren't internally consistent.
UAssetRebuildResult rebuildUAssetWithNamePatches({
  required Uint8List data,
  required String packageNameNew,
  required List<NameTablePatch> nameTablePatches,
}) {
  if (data.length < 0x24) {
    throw const UAssetRebuildError('uasset too short to read PackageName length');
  }
  final view = ByteData.sublistView(data);
  final pkgLenOld = view.getInt32(0x20, Endian.little);
  if (pkgLenOld <= 0 || 0x24 + pkgLenOld > data.length) {
    throw UAssetRebuildError(
        'invalid PackageName length: $pkgLenOld (data ${data.length} bytes)');
  }
  final fse = 0x24 + pkgLenOld;
  if (fse + 12 > data.length) {
    throw const UAssetRebuildError('uasset too short past PackageName header');
  }
  final nameCount = view.getInt32(fse + 4, Endian.little);
  final nameOffset = view.getInt32(fse + 8, Endian.little);
  if (nameOffset < fse || nameOffset > data.length) {
    throw UAssetRebuildError(
        'invalid name_offset: $nameOffset (fse=$fse, len=${data.length})');
  }

  // ── Assemble the new bytes ───────────────────────────────────────────
  final builder = BytesBuilder(copy: true);
  // Header up through PackageName length field (PackageName length itself
  // is rewritten next, so we copy bytes [0..0x20) only).
  builder.add(data.sublist(0, 0x20));

  // New PackageName: length-prefix + UTF-8 bytes + NUL terminator.
  final newPkgUtf8 = utf8.encode(packageNameNew);
  final newPkgWithNul = Uint8List(newPkgUtf8.length + 1)
    ..setRange(0, newPkgUtf8.length, newPkgUtf8);
  // index newPkgUtf8.length is left as 0 (NUL) by Uint8List default-init.
  builder.add(_int32LeBytes(newPkgWithNul.length));
  builder.add(newPkgWithNul);

  final newFse = builder.length;

  // Pre-name-table region.
  builder.add(data.sublist(fse, nameOffset));
  final newNameOffset = builder.length;

  // ── Walk name table, applying patches ──────────────────────────────
  var pos = nameOffset;
  var patchedCount = 0;
  for (var i = 0; i < nameCount; i++) {
    if (pos + 4 > data.length) break;
    final slen = view.getInt32(pos, Endian.little);
    if (slen <= 0 || slen > 500) break;
    if (pos + 4 + slen + 4 > data.length) break;

    var entryBytes = data.sublist(pos + 4, pos + 4 + slen); // includes NUL
    var hashVal = view.getUint32(pos + 4 + slen, Endian.little);

    // Decode without the trailing NUL (Python: `s_bytes[:-1].decode(...)`).
    final body = entryBytes.sublist(0, entryBytes.length - 1);
    var s = utf8.decode(body, allowMalformed: true);

    var patched = false;
    for (final patch in nameTablePatches) {
      if (patch.old.isNotEmpty && s.contains(patch.old)) {
        s = s.replaceAll(patch.old, patch.replacement);
        patched = true;
      }
    }

    if (patched) {
      final newUtf8 = utf8.encode(s);
      entryBytes = Uint8List(newUtf8.length + 1)
        ..setRange(0, newUtf8.length, newUtf8);
      hashVal = 0; // invalidate FName hash
      patchedCount++;
    }

    builder.add(_int32LeBytes(entryBytes.length));
    builder.add(entryBytes);
    builder.add(_uint32LeBytes(hashVal));
    pos += 4 + slen + 4;
  }

  // Copy everything after the name table verbatim.
  builder.add(data.sublist(pos));

  // Fresh mutable Uint8List so we can patch offsets in place.
  final newBytes = Uint8List.fromList(builder.toBytes());
  final totalShift = newBytes.length - data.length;

  // ── Fix offset fields in the export-header section ───────────────────
  final newView = ByteData.sublistView(newBytes);
  newView.setInt32(newFse + 8, newNameOffset, Endian.little);

  for (final rel in const [16, 32, 40, 44, 136, 160, 176]) {
    final absPos = newFse + rel;
    if (absPos + 4 > newBytes.length) continue;
    final oldVal = newView.getInt32(absPos, Endian.little);
    if (oldVal > 0) {
      newView.setInt32(absPos, oldVal + totalShift, Endian.little);
    }
  }

  // ── Patch export[0].SerialOffset (= total file length) ──────────────
  final newExportOff = newView.getInt32(newFse + 32, Endian.little);
  final newExportCount = newView.getInt32(newFse + 28, Endian.little);
  if (newExportOff > 0 && newExportOff + 44 <= newBytes.length) {
    newView.setInt64(newExportOff + 36, newBytes.length, Endian.little);
  }

  // ── Multi-export shift (Blueprints) ─────────────────────────────────
  // Detect export-record stride by probing against the original asset's
  // expected `e0_off + e0_size`.  Single-export assets fall through.
  if (newExportCount > 1 && totalShift != 0) {
    final origExportOff = view.getInt32(fse + 32, Endian.little);
    if (origExportOff > 0 && origExportOff + 44 <= data.length) {
      final e0Size = view.getInt64(origExportOff + 28, Endian.little);
      final e0Off = view.getInt64(origExportOff + 36, Endian.little);
      final expectedE1Off = e0Off + e0Size;

      int? detectedEsz;
      for (final candidate in const [96, 104, 100, 88, 112]) {
        final probe = origExportOff + candidate + 36;
        if (probe + 8 > data.length) continue;
        if (view.getInt64(probe, Endian.little) == expectedE1Off) {
          detectedEsz = candidate;
          break;
        }
      }
      if (detectedEsz != null) {
        for (var i = 1; i < newExportCount; i++) {
          final baseNew = newExportOff + i * detectedEsz;
          if (baseNew + 44 > newBytes.length) break;
          final oldV = newView.getInt64(baseNew + 36, Endian.little);
          if (oldV > 0) {
            newView.setInt64(baseNew + 36, oldV + totalShift, Endian.little);
          }
        }
      }
    }
  }

  return UAssetRebuildResult(
    bytes: newBytes,
    totalShift: totalShift,
    patchedNames: patchedCount,
  );
}

Uint8List _int32LeBytes(int value) {
  final b = ByteData(4)..setInt32(0, value, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _uint32LeBytes(int value) {
  final b = ByteData(4)..setUint32(0, value, Endian.little);
  return b.buffer.asUint8List();
}
