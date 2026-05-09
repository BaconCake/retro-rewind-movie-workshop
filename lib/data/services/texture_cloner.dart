/// Port of `clone_texture_3digit` from RR_VHS_Tool.py:2689-2835.
///
/// Clones a `T_Bkg` / `T_New` uasset to a new slot number, performing the
/// FName / FString surgery the UE5 asset format demands.
///
/// Two encoding styles based on the destination slot number:
///   * **dst 1-99** — full literal name in the name table
///     (e.g. `T_Bkg_Dra_001`), `stored_number = 0`.
///     Matches base-game style for slots 01-09.
///   * **dst 100+** — base name in the name table (e.g. `T_Bkg_Dra`),
///     `stored_number = N+1`.  Matches base-game style for slots 10+.
///
/// The PackageName FString always carries the full literal path and may
/// change length, so the file is rebuilt section-by-section instead of
/// patched in place.  Every offset, magic-number, and string pattern in
/// this file is load-bearing — see the Python source for derivation.
library;

import 'dart:typed_data';

const String _kBackgroundPathPrefix =
    '/Game/VideoStore/asset/prop/vhs/Background';

/// Build a new uasset that names slot ([dstCode], [dstNum]) by cloning
/// the bytes of slot ([srcCode], [srcNum]) given as [srcData].
///
/// Mirrors RR_VHS_Tool.py:2689-2835 line-for-line.  Do not refactor
/// without parity tests against Python-produced clones.
Uint8List cloneTexture3digit({
  required Uint8List srcData,
  required String srcCode,
  required int srcNum,
  required String dstCode,
  required int dstNum,
}) {
  final data = Uint8List.fromList(srcData);
  final bd = ByteData.sublistView(data);

  // Detect the prefix by scanning the first 0x90 bytes for a `T_New_` marker
  // (vs the more common `T_Bkg_`).  Python: line 2705.
  final prefix = _containsAscii(data, 0, 0x90, 'T_New_') ? 'T_New' : 'T_Bkg';

  // Folder is always `T_Bkg_<code>` even for `T_New` textures — the on-disk
  // layout puts new-release entries inside the genre's bkg folder.  Python
  // computes srcFolder too but never references it; we skip the dead variable.
  final dstFolder = 'T_Bkg_$dstCode';

  final oldShort = srcNum < 100
      ? '${prefix}_${srcCode}_${_pad2(srcNum)}'
      : '${prefix}_${srcCode}_$srcNum';
  final newShort = dstNum < 100
      ? '${prefix}_${dstCode}_${_pad3(dstNum)}'
      : '${prefix}_${dstCode}_$dstNum';

  final newPath = '$_kBackgroundPathPrefix/$dstFolder/$newShort';

  final useLiteral = dstNum < 100;
  final srcBase = '${prefix}_$srcCode';
  final dstBase = '${prefix}_$dstCode';

  // --- Parse the existing structure ---
  // Layout (RR_VHS_Tool.py:2722-2725):
  //   0x20 : i32  pkg_len  (length of PackageName FString incl. NUL)
  //   0x24 : utf8 PackageName, NUL-terminated
  //   fse  = 0x24 + pkg_len  (start of file summary header fields)
  //   fse+4: i32  name_count
  //   fse+8: i32  name_offset (absolute)
  final pkgLen = bd.getInt32(0x20, Endian.little);
  final fse = 0x24 + pkgLen;
  final nameCount = bd.getInt32(fse + 4, Endian.little);
  final nameOffset = bd.getInt32(fse + 8, Endian.little);

  // Determine the destination name-table entries based on encoding style.
  final String dstPathEntry;
  final String dstShortEntry;
  final int dstStoredNumber;
  if (useLiteral) {
    dstPathEntry = '$_kBackgroundPathPrefix/$dstFolder/$newShort';
    dstShortEntry = newShort;
    dstStoredNumber = 0;
  } else {
    dstPathEntry = '$_kBackgroundPathPrefix/$dstFolder/$dstBase';
    dstShortEntry = dstBase;
    dstStoredNumber = dstNum + 1;
  }

  // --- Rebuild the file section by section ---
  final out = BytesBuilder(copy: false);

  // Pre-package header (0x00..0x1F) is copied verbatim.
  out.add(data.sublist(0, 0x20));

  // New PackageName FString (length prefix + bytes + NUL).
  final newPkgBytes = Uint8List.fromList([..._utf8(newPath), 0]);
  out.add(_packInt32(newPkgBytes.length));
  out.add(newPkgBytes);
  final newFse = out.length;

  // File summary header bytes between fse and the start of the name table.
  out.add(data.sublist(fse, nameOffset));
  final newNameOffset = out.length;

  // Walk the name table, patching path / short-name entries on the fly.
  // Each entry: i32 length, length bytes (incl. NUL), u32 hash.
  var ntPos = nameOffset;
  for (var i = 0; i < nameCount; i++) {
    final sLen = bd.getInt32(ntPos, Endian.little);
    final sBytes = data.sublist(ntPos + 4, ntPos + 4 + sLen);
    var hashVal = bd.getUint32(ntPos + 4 + sLen, Endian.little);
    // Strip trailing NUL for comparison purposes (the bytes preserve it).
    final sStr = _decodeUtf8Lossy(sBytes.sublist(0, sBytes.length - 1));

    Uint8List outBytes;
    if (sStr.startsWith('$_kBackgroundPathPrefix/') &&
        (sStr.contains(srcBase) || sStr.contains(oldShort))) {
      outBytes = Uint8List.fromList([..._utf8(dstPathEntry), 0]);
      hashVal = 0;
    } else if (sStr == srcBase || sStr == oldShort) {
      outBytes = Uint8List.fromList([..._utf8(dstShortEntry), 0]);
      hashVal = 0;
    } else {
      outBytes = sBytes;
    }

    out.add(_packInt32(outBytes.length));
    out.add(outBytes);
    out.add(_packUint32(hashVal));

    ntPos += 4 + sLen + 4;
  }

  // Everything after the name table is copied verbatim.
  out.add(data.sublist(ntPos));

  final newData = Uint8List.fromList(out.toBytes());
  final totalShift = newData.length - data.length;
  final newBd = ByteData.sublistView(newData);

  // Patch the name table offset to point at our (possibly relocated) table.
  newBd.setInt32(newFse + 8, newNameOffset, Endian.little);

  // Other absolute offsets in the file summary that need shifting when the
  // name table grew/shrank.  Each entry holds an i32 absolute offset; if the
  // old value was non-zero, add the section shift.  RR_VHS_Tool.py:2793-2798.
  for (final rel in const [16, 32, 40, 44, 136, 160, 176]) {
    final absPos = newFse + rel;
    if (absPos + 4 > newData.length) continue;
    final oldVal = newBd.getInt32(absPos, Endian.little);
    if (oldVal > 0) {
      newBd.setInt32(absPos, oldVal + totalShift, Endian.little);
    }
  }

  // Fix the export entry: stored_number at +20, serial_offset at +36 (i64).
  // RR_VHS_Tool.py:2800-2806.
  final newExportOff = newBd.getInt32(newFse + 32, Endian.little);
  if (newExportOff + 44 <= newData.length) {
    newBd.setUint32(newExportOff + 20, dstStoredNumber, Endian.little);
    newBd.setInt64(newExportOff + 36, newData.length, Endian.little);
  }

  // For base+stored_number style (dst slot >= 100), also patch any other
  // FName pairs (e.g. inside the import table) that referenced the source
  // slot's stored_number.  RR_VHS_Tool.py:2810-2833.
  if (!useLiteral) {
    int? dstBaseIdx;
    var p2 = newBd.getInt32(newFse + 8, Endian.little);
    for (var i = 0; i < nameCount; i++) {
      if (p2 + 4 > newData.length) break;
      final sl = newBd.getInt32(p2, Endian.little);
      if (sl <= 0 || sl > 500) break;
      final s = _decodeUtf8Lossy(
          newData.sublist(p2 + 4, p2 + 4 + sl - 1));
      if (s == dstBase) {
        dstBaseIdx = i;
        break;
      }
      p2 += 4 + sl + 4;
    }

    if (dstBaseIdx != null) {
      final srcStored = srcNum + 1;
      final srcPair = Uint8List(8);
      ByteData.sublistView(srcPair)
        ..setUint32(0, dstBaseIdx, Endian.little)
        ..setUint32(4, srcStored, Endian.little);
      final dstPair = Uint8List(8);
      ByteData.sublistView(dstPair)
        ..setUint32(0, dstBaseIdx, Endian.little)
        ..setUint32(4, dstStoredNumber, Endian.little);

      var pos = 0;
      while (true) {
        final found = _indexOf(newData, srcPair, pos);
        if (found < 0) break;
        newData.setRange(found, found + 8, dstPair);
        pos = found + 8;
      }
    }
  }

  return newData;
}

/// Length-preserving rename of a 2-digit T_New uasset.  Pure port of
/// `_patch_legacy_2digit_uasset` (RR_VHS_Tool.py:2424-2481).
///
/// Renames `T_New_<srcCode>_<srcNum:02d>` → `T_New_<dstCode>_<dstNum:02d>`
/// and the matching folder `T_Bkg_<srcCode>` → `T_Bkg_<dstCode>` in:
///   * the PackageName FString at offset `0x24`,
///   * every name-table entry that contains either substring.
/// Touched name-table entries also get their FName hash zeroed so UE
/// rehashes from the patched string at load (matches Python).
///
/// Donor and target short names are both 12 chars (`T_New_XXX_NN`),
/// folders are both 9 chars (`T_Bkg_XXX`) — so all SerialOffsets and
/// `serial_size` fields stay valid and the file is the same length as
/// the input.  No header rewriting needed; we patch in place.
///
/// Used by the v1.8.2.2 OOR co-inject path: 2-digit slots beyond the
/// genre's `base_new_count` don't exist in the base pak, so we synthesize
/// them by cloning `T_New_Hor_01` (always extractable, Hor has
/// `newCount=4`).  Throws [ArgumentError] when any rename would change
/// length (sanity guard against future code changes — the caller's
/// `srcCode`/`dstCode` must both be exactly 3 chars).
Uint8List patchLegacy2DigitUasset({
  required Uint8List srcData,
  required String srcCode,
  required int srcNum,
  required String dstCode,
  required int dstNum,
}) {
  final srcShort = 'T_New_${srcCode}_${_pad2(srcNum)}';
  final dstShort = 'T_New_${dstCode}_${_pad2(dstNum)}';
  final srcFolder = 'T_Bkg_$srcCode';
  final dstFolder = 'T_Bkg_$dstCode';
  if (srcShort.length != dstShort.length ||
      srcFolder.length != dstFolder.length) {
    throw ArgumentError(
      'length-preserving rename requires equal lengths: '
      '"$srcShort"->"$dstShort", "$srcFolder"->"$dstFolder"',
    );
  }
  if (srcNum < 1 || srcNum > 99 || dstNum < 1 || dstNum > 99) {
    throw ArgumentError(
      'srcNum/dstNum must be in 1..99 (2-digit padding), '
      'got srcNum=$srcNum dstNum=$dstNum',
    );
  }

  final data = Uint8List.fromList(srcData);
  final view = ByteData.sublistView(data);

  final srcShortB = _utf8(srcShort);
  final dstShortB = _utf8(dstShort);
  final srcFolderB = _utf8(srcFolder);
  final dstFolderB = _utf8(dstFolder);

  // ── Patch PackageName FString (length-prefixed, NUL-terminated, at 0x24)
  if (data.length < 0x24 + 4) {
    throw ArgumentError('uasset too short to read PackageName length');
  }
  final pkgLen = view.getInt32(0x20, Endian.little);
  if (pkgLen <= 0 || 0x24 + pkgLen > data.length) {
    throw ArgumentError('invalid PackageName length: $pkgLen');
  }
  // pkgStr excludes the trailing NUL (Python: `pkg_str = data[0x24:0x24+pkg_len-1]`).
  final pkgStr = data.sublist(0x24, 0x24 + pkgLen - 1);
  final newPkg =
      _replaceAll(_replaceAll(pkgStr, srcShortB, dstShortB), srcFolderB, dstFolderB);
  if (newPkg.length != pkgStr.length) {
    throw StateError('PackageName length changed unexpectedly');
  }
  data.setRange(0x24, 0x24 + newPkg.length, newPkg);

  // ── Patch name table entries
  final fse = 0x24 + pkgLen;
  if (fse + 12 > data.length) {
    throw ArgumentError('uasset too short to read name table header');
  }
  final nameCount = view.getInt32(fse + 4, Endian.little);
  final nameOffset = view.getInt32(fse + 8, Endian.little);
  if (nameOffset < fse || nameOffset > data.length) {
    throw ArgumentError('invalid name_offset: $nameOffset');
  }

  var pos = nameOffset;
  for (var i = 0; i < nameCount; i++) {
    if (pos + 4 > data.length) break;
    final slen = view.getInt32(pos, Endian.little);
    if (slen <= 0 || slen > 500) break;
    if (pos + 4 + slen + 4 > data.length) break;

    final entryBytes = data.sublist(pos + 4, pos + 4 + slen);
    final newBytes = _replaceAll(
        _replaceAll(entryBytes, srcShortB, dstShortB), srcFolderB, dstFolderB);
    if (!_byteListEqual(newBytes, entryBytes)) {
      if (newBytes.length != entryBytes.length) {
        throw StateError(
          'name table entry length changed: ${_decodeUtf8Lossy(entryBytes)} -> '
          '${_decodeUtf8Lossy(newBytes)}',
        );
      }
      data.setRange(pos + 4, pos + 4 + slen, newBytes);
      // Zero the 4-byte FName hash that follows; UE re-hashes on load.
      view.setUint32(pos + 4 + slen, 0, Endian.little);
    }
    pos += 4 + slen + 4;
  }

  return data;
}

/// Replace every non-overlapping occurrence of [needle] in [haystack]
/// with [replacement].  Both byte sequences may have different lengths
/// (caller is responsible for length validation when needed).
Uint8List _replaceAll(
    Uint8List haystack, Uint8List needle, Uint8List replacement) {
  if (needle.isEmpty || haystack.length < needle.length) return haystack;
  // Same-length fast path: in-place mutation on a copy.
  if (needle.length == replacement.length) {
    final out = Uint8List.fromList(haystack);
    final last = out.length - needle.length;
    outer:
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (out[i + j] != needle[j]) continue outer;
      }
      out.setRange(i, i + replacement.length, replacement);
      i += needle.length - 1;
    }
    return out;
  }
  // Length-changing path: rebuild via BytesBuilder.
  final builder = BytesBuilder(copy: false);
  var i = 0;
  while (i < haystack.length) {
    if (i + needle.length <= haystack.length) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        builder.add(replacement);
        i += needle.length;
        continue;
      }
    }
    builder.addByte(haystack[i]);
    i++;
  }
  return Uint8List.fromList(builder.toBytes());
}

bool _byteListEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

String _pad2(int n) => n.toString().padLeft(2, '0');
String _pad3(int n) => n.toString().padLeft(3, '0');

Uint8List _utf8(String s) {
  // ASCII-safe path: every string we ever pass here is plain ASCII so a
  // hand-rolled encoder avoids importing dart:convert just for this.
  return Uint8List.fromList(s.codeUnits);
}

String _decodeUtf8Lossy(Uint8List bytes) {
  // Same shortcut: paths and FNames are ASCII-only, so codeUnit decode is
  // safe.  Matches Python's `.decode('utf-8', 'replace')` for our inputs.
  return String.fromCharCodes(bytes);
}

Uint8List _packInt32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setInt32(0, v, Endian.little);
  return out;
}

Uint8List _packUint32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v, Endian.little);
  return out;
}

bool _containsAscii(Uint8List data, int start, int end, String needle) {
  return _indexOf(data, Uint8List.fromList(needle.codeUnits), start,
          endExclusive: end) >=
      0;
}

/// Find [needle] in [haystack] starting at [start] (inclusive).  Returns -1
/// when not found.  Optional [endExclusive] caps the search range.
int _indexOf(Uint8List haystack, Uint8List needle, int start,
    {int? endExclusive}) {
  if (needle.isEmpty) return start;
  final end = (endExclusive ?? haystack.length) - needle.length;
  outer:
  for (var i = start; i <= end; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
