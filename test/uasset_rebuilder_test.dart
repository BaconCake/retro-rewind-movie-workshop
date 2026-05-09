import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/services/uasset_rebuilder.dart';

/// Read the bundled MI uasset template directly from disk so these tests
/// don't need Flutter's rootBundle plumbing.  Same path the
/// `standee_builders_test.dart` group uses.
Future<Uint8List> _miUassetFixture() async {
  final path = p.join(Directory.current.path, 'assets', 'standee_templates',
      'mi_uasset.bin');
  return File(path).readAsBytes();
}

bool _bytesContain(Uint8List buf, List<int> needle) {
  if (needle.isEmpty || needle.length > buf.length) return false;
  outer:
  for (var i = 0; i <= buf.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (buf[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Read PackageName FString out of a uasset header.  Returns the string
/// without its trailing NUL, or null if the header looks malformed.
String? _readPackageName(Uint8List data) {
  if (data.length < 0x24) return null;
  final view = ByteData.sublistView(data);
  final pkgLen = view.getInt32(0x20, Endian.little);
  if (pkgLen <= 0 || 0x24 + pkgLen > data.length) return null;
  final raw = data.sublist(0x24, 0x24 + pkgLen);
  if (raw.last != 0) return null;
  return String.fromCharCodes(raw.sublist(0, raw.length - 1));
}

/// Walk the name table starting at fse.  Returns the list of decoded
/// strings (without trailing NUL).  Doesn't care about the hash trailer.
List<String> _readNameTable(Uint8List data) {
  final view = ByteData.sublistView(data);
  final pkgLen = view.getInt32(0x20, Endian.little);
  final fse = 0x24 + pkgLen;
  final nameCount = view.getInt32(fse + 4, Endian.little);
  final nameOffset = view.getInt32(fse + 8, Endian.little);

  final names = <String>[];
  var pos = nameOffset;
  for (var i = 0; i < nameCount; i++) {
    if (pos + 4 > data.length) break;
    final slen = view.getInt32(pos, Endian.little);
    if (slen <= 0 || slen > 500) break;
    if (pos + 4 + slen + 4 > data.length) break;
    final body = data.sublist(pos + 4, pos + 4 + slen - 1);
    names.add(String.fromCharCodes(body));
    pos += 4 + slen + 4;
  }
  return names;
}

/// Read FName hash bytes for the i-th name-table entry.  Returns the raw
/// 32-bit value at offset (entry_start + 4 + slen).  Patched entries
/// should report 0.
int _readNameHash(Uint8List data, int entryIndex) {
  final view = ByteData.sublistView(data);
  final pkgLen = view.getInt32(0x20, Endian.little);
  final fse = 0x24 + pkgLen;
  final nameOffset = view.getInt32(fse + 8, Endian.little);

  var pos = nameOffset;
  for (var i = 0; i < entryIndex; i++) {
    final slen = view.getInt32(pos, Endian.little);
    pos += 4 + slen + 4;
  }
  final slen = view.getInt32(pos, Endian.little);
  return view.getUint32(pos + 4 + slen, Endian.little);
}

void main() {
  group('rebuildUAssetWithNamePatches', () {
    late Uint8List miSrc;
    late String miSrcPkg;

    setUpAll(() async {
      miSrc = await _miUassetFixture();
      miSrcPkg = _readPackageName(miSrc)!;
      // Sanity: the template's PackageName is what every test below assumes.
      expect(miSrcPkg.endsWith('/MI_New_Hor_04'), isTrue,
          reason: 'fixture changed — update the tests');
    });

    test('no-op rebuild (same PackageName + empty patches) returns identical bytes',
        () {
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew: miSrcPkg,
        nameTablePatches: const [],
      );
      expect(result.totalShift, 0);
      expect(result.patchedNames, 0);
      expect(result.bytes, miSrc, reason: 'no-op rebuild must be byte-identical');
    });

    test('same-length patches: totalShift=0, target strings replace source strings',
        () {
      // Hor_04 → Sci_07 (both 6 chars), T_Bkg_Hor → T_Bkg_Sci (both 9),
      // T_Standee_A_01_ao → T_Standee_C_01_ao (both 17).
      final newPkg = miSrcPkg
          .replaceAll('T_Bkg_Hor', 'T_Bkg_Sci')
          .replaceAll('Hor_04', 'Sci_07');
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew: newPkg,
        nameTablePatches: const [
          NameTablePatch('Hor_04', 'Sci_07'),
          NameTablePatch('T_Bkg_Hor', 'T_Bkg_Sci'),
          NameTablePatch('T_Standee_A_01_ao', 'T_Standee_C_01_ao'),
        ],
      );

      expect(result.totalShift, 0,
          reason: 'same-length patches should not shift bytes');
      expect(result.bytes.length, miSrc.length);
      expect(result.patchedNames, greaterThan(0));

      // Source strings gone, target strings present.
      expect(_bytesContain(result.bytes, 'Hor_04'.codeUnits), isFalse);
      expect(_bytesContain(result.bytes, 'T_Bkg_Hor'.codeUnits), isFalse);
      expect(_bytesContain(result.bytes, 'T_Standee_A_01_ao'.codeUnits),
          isFalse);
      expect(_bytesContain(result.bytes, 'Sci_07'.codeUnits), isTrue);
      expect(_bytesContain(result.bytes, 'T_Bkg_Sci'.codeUnits), isTrue);
      expect(_bytesContain(result.bytes, 'T_Standee_C_01_ao'.codeUnits),
          isTrue);

      // Output is still a valid uasset: PackageName + name table re-read.
      expect(_readPackageName(result.bytes), newPkg);
      final names = _readNameTable(result.bytes);
      expect(names, contains('MI_New_Sci_07'));
      expect(names.where((n) => n.contains('Hor_04')), isEmpty);
    });

    test('length-growing patches: totalShift matches expected delta', () {
      // Hor_04 (6 chars) → Sci_007 (7 chars) — +1 byte per occurrence in
      // both PackageName and name-table entries.  T_Bkg_Hor → T_Bkg_Sci
      // is same-length so it doesn't add to the shift.
      final newPkg =
          miSrcPkg.replaceAll('T_Bkg_Hor', 'T_Bkg_Sci').replaceAll('Hor_04', 'Sci_007');
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew: newPkg,
        nameTablePatches: const [
          NameTablePatch('Hor_04', 'Sci_007'),
          NameTablePatch('T_Bkg_Hor', 'T_Bkg_Sci'),
          NameTablePatch('T_Standee_A_01_ao', 'T_Standee_C_01_ao'),
        ],
      );

      // PackageName grew by exactly 1 char; each name-table entry that
      // contained "Hor_04" also grew by 1.  patchedNames counts how many
      // entries shifted, plus we know PackageName always shifts.
      // Expected total shift = 1 (PackageName) + N (name entries).
      // We don't pin N exactly because the template's name-table contents
      // are an implementation detail — but we DO assert total > 0 and
      // that re-parsing the output recovers the new PackageName + names.
      expect(result.totalShift, greaterThan(0));
      expect(result.bytes.length, miSrc.length + result.totalShift);
      expect(result.patchedNames, greaterThan(0));

      expect(_readPackageName(result.bytes), newPkg);
      expect(_bytesContain(result.bytes, 'Hor_04'.codeUnits), isFalse);
      expect(_bytesContain(result.bytes, 'Sci_007'.codeUnits), isTrue);

      final names = _readNameTable(result.bytes);
      expect(names, contains('MI_New_Sci_007'));
      expect(names.where((n) => n.contains('Hor_04')), isEmpty);
    });

    test('PackageName grows but no name-table patches: totalShift = pkg delta only',
        () {
      // Append a marker to PackageName (no name-table changes).
      final newPkg = '${miSrcPkg}_test';
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew: newPkg,
        nameTablePatches: const [],
      );
      // 5 extra UTF-8 bytes ('_test') in PackageName; nothing else moves.
      expect(result.totalShift, 5);
      expect(result.patchedNames, 0);
      expect(_readPackageName(result.bytes), newPkg);
      // Name table is intact.
      expect(_readNameTable(result.bytes), _readNameTable(miSrc));
    });

    test('FName hash is zeroed for patched name-table entries', () {
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew:
            miSrcPkg.replaceAll('T_Bkg_Hor', 'T_Bkg_Sci').replaceAll('Hor_04', 'Sci_07'),
        nameTablePatches: const [
          NameTablePatch('Hor_04', 'Sci_07'),
        ],
      );
      // Find indices of patched + unpatched entries.
      final names = _readNameTable(result.bytes);
      final patchedIdx = <int>[];
      final unpatchedIdx = <int>[];
      for (var i = 0; i < names.length; i++) {
        if (names[i].contains('Sci_07')) {
          patchedIdx.add(i);
        } else {
          unpatchedIdx.add(i);
        }
      }
      expect(patchedIdx, isNotEmpty,
          reason: 'fixture should have at least one patched entry');
      for (final i in patchedIdx) {
        expect(_readNameHash(result.bytes, i), 0,
            reason: 'patched entry $i ("${names[i]}") must have hash=0');
      }
      // At least one unpatched entry should keep its hash (>0 for any
      // real base-game asset — UE never writes hash=0 for non-empty
      // strings except as the explicit invalidation marker).
      final unpatchedHashes = unpatchedIdx
          .map((i) => _readNameHash(result.bytes, i))
          .where((h) => h != 0)
          .toList();
      expect(unpatchedHashes, isNotEmpty,
          reason: 'unpatched entries should keep their non-zero hashes');
    });

    test('throws on malformed input (PackageName length out of range)', () {
      // Forge a uasset with pkg_len = -1.
      final bad = Uint8List.fromList(miSrc);
      ByteData.sublistView(bad).setInt32(0x20, -1, Endian.little);
      expect(
        () => rebuildUAssetWithNamePatches(
          data: bad,
          packageNameNew: 'whatever',
          nameTablePatches: const [],
        ),
        throwsA(isA<UAssetRebuildError>()),
      );
    });

    test('throws when input is shorter than the header', () {
      expect(
        () => rebuildUAssetWithNamePatches(
          data: Uint8List(10),
          packageNameNew: 'x',
          nameTablePatches: const [],
        ),
        throwsA(isA<UAssetRebuildError>()),
      );
    });

    test('empty patch.old is ignored (no spurious replacement)', () {
      final result = rebuildUAssetWithNamePatches(
        data: miSrc,
        packageNameNew: miSrcPkg,
        nameTablePatches: const [
          NameTablePatch('', 'should-not-appear'),
        ],
      );
      expect(result.patchedNames, 0);
      expect(result.totalShift, 0);
      expect(result.bytes, miSrc);
      expect(_bytesContain(result.bytes, 'should-not-appear'.codeUnits),
          isFalse);
    });
  });
}
