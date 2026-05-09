import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/data/services/texture_cloner.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

/// Integration test for `cloneTexture3digit` against a real base-game
/// `T_Bkg_Wst_10.uasset` extracted via `PakCache`.  This is the load-bearing
/// case for slice 3b: the user's `replacements.json` keys are all 3-digit
/// custom slots (e.g. `T_Bkg_Wst_001`), and the cloner has to produce the
/// uasset for them by patching the base game's last 2-digit slot
/// (`T_Bkg_Wst_10`).
///
/// Self-skips with a clear message when no working `config.json` is present
/// — same pattern as `datatable_parser_test.dart`.
void main() {
  group('cloneTexture3digit (against base game fixtures)', () {
    late AppConfig config;
    late PakCache cache;
    late bool fixturesAvailable;

    setUpAll(() async {
      final cwd = Directory.current.path;
      final configPath = p.join(cwd, 'config.json');
      if (!File(configPath).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      final json = await JsonFileDataSource().readJson(configPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      config = ConfigDto.fromJson(json).toEntity();
      if (config.repak.isEmpty || config.baseGamePak.isEmpty) {
        fixturesAvailable = false;
        return;
      }
      cache = PakCache(cwd);
      // Make sure the Western T_Bkg folder is extracted; idempotent on hit.
      final res = await cache.extractFolder(config,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_Wst/');
      fixturesAvailable = res.ok;
    });

    test('clones T_Bkg_Wst_10 → T_Bkg_Wst_001 with the right embedded names',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or base pak unavailable');
        return;
      }
      final srcPath = p.join(
          cache.extractDir,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_Wst/T_Bkg_Wst_10.uasset'
              .replaceAll('/', p.separator));
      final src = await File(srcPath).readAsBytes();

      final cloned = cloneTexture3digit(
        srcData: src,
        srcCode: 'Wst',
        srcNum: 10,
        dstCode: 'Wst',
        dstNum: 1,
      );

      // Length should change (the literal new path is longer than what was
      // there before since slot 10 used the base+stored_number style).
      expect(cloned.length, isNot(equals(src.length)),
          reason: 'cloning across encoding styles must change file length');

      // The new package path / short name must appear verbatim in the bytes.
      expect(_containsAscii(cloned, 'T_Bkg_Wst_001'), isTrue,
          reason: 'new short name "T_Bkg_Wst_001" must be present');
      expect(
          _containsAscii(cloned,
              '/Game/VideoStore/asset/prop/vhs/Background/T_Bkg_Wst/T_Bkg_Wst_001'),
          isTrue,
          reason: 'new full path must be present');

      // The old short name should be gone (the source was the only carrier).
      expect(_containsAscii(cloned, 'T_Bkg_Wst_10'), isFalse,
          reason: 'old short name must be replaced everywhere');
    });

    test('clones T_Bkg_Wst_10 → T_Bkg_Wst_023 in base+stored_number style',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or base pak unavailable');
        return;
      }
      // dst slot 23 is >= 10 so it uses the base+stored_number encoding.
      // The name table should hold the BASE name "T_Bkg_Wst" rather than a
      // literal "T_Bkg_Wst_023".
      final srcPath = p.join(
          cache.extractDir,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_Wst/T_Bkg_Wst_10.uasset'
              .replaceAll('/', p.separator));
      final src = await File(srcPath).readAsBytes();

      final cloned = cloneTexture3digit(
        srcData: src,
        srcCode: 'Wst',
        srcNum: 10,
        dstCode: 'Wst',
        dstNum: 23,
      );

      // Full path FString should reference the literal new short name.
      expect(
          _containsAscii(cloned,
              '/Game/VideoStore/asset/prop/vhs/Background/T_Bkg_Wst/T_Bkg_Wst_023'),
          isTrue);

      // We don't assert the *absence* of `T_Bkg_Wst_023` as a short string in
      // the name table here — that would require parsing the table to verify
      // structure rather than just byte presence.  The path FString legitimately
      // contains the substring.
    });
  });

  /// Tests for the v1.8.2.2 length-preserving OOR clone helper.  Like
  /// [cloneTexture3digit] but for 2-digit targets — donor and target are
  /// both 12 chars (`T_New_XXX_NN`), folders both 9 chars (`T_Bkg_XXX`),
  /// so no SerialOffset shifting is needed.
  group('patchLegacy2DigitUasset (against T_New_Hor_01 fixture)', () {
    late AppConfig config;
    late PakCache cache;
    late bool fixturesAvailable;

    setUpAll(() async {
      final cwd = Directory.current.path;
      final configPath = p.join(cwd, 'config.json');
      if (!File(configPath).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      final json = await JsonFileDataSource().readJson(configPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      config = ConfigDto.fromJson(json).toEntity();
      if (config.repak.isEmpty || config.baseGamePak.isEmpty) {
        fixturesAvailable = false;
        return;
      }
      cache = PakCache(cwd);
      final res = await cache.extractFolder(config,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_Hor/');
      fixturesAvailable = res.ok;
    });

    Future<List<int>> readDonor() async {
      final path = p.join(
          cache.extractDir,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_Hor/T_New_Hor_01.uasset'
              .replaceAll('/', p.separator));
      return File(path).readAsBytes();
    }

    test('patches Hor_01 → Sci_05 with length-preserving rename', () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or base pak unavailable');
        return;
      }
      final src = Uint8List.fromList(await readDonor());
      final patched = patchLegacy2DigitUasset(
        srcData: src,
        srcCode: 'Hor',
        srcNum: 1,
        dstCode: 'Sci',
        dstNum: 5,
      );
      // Same-length invariant — defining property of v1.8.2.2 OOR path.
      expect(patched.length, src.length);
      // Source strings gone.
      expect(_containsAscii(patched, 'T_New_Hor_01'), isFalse,
          reason: 'donor short name must be replaced everywhere');
      expect(_containsAscii(patched, 'T_Bkg_Hor'), isFalse,
          reason: 'donor folder must be replaced everywhere');
      // Target strings present.
      expect(_containsAscii(patched, 'T_New_Sci_05'), isTrue);
      expect(_containsAscii(patched, 'T_Bkg_Sci'), isTrue);
      // Full PackageName updated.
      expect(
          _containsAscii(patched,
              '/Game/VideoStore/asset/prop/vhs/Background/T_Bkg_Sci/T_New_Sci_05'),
          isTrue);
    });

    test('no-op when src == dst (Hor_01 → Hor_01) returns identical bytes',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or base pak unavailable');
        return;
      }
      final src = Uint8List.fromList(await readDonor());
      final patched = patchLegacy2DigitUasset(
        srcData: src,
        srcCode: 'Hor',
        srcNum: 1,
        dstCode: 'Hor',
        dstNum: 1,
      );
      expect(patched.length, src.length);
      expect(patched, src,
          reason: 'no patches applied — output must be byte-identical');
    });

    test('FName hashes are zeroed for patched name-table entries', () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or base pak unavailable');
        return;
      }
      final src = Uint8List.fromList(await readDonor());
      final patched = patchLegacy2DigitUasset(
        srcData: src,
        srcCode: 'Hor',
        srcNum: 1,
        dstCode: 'Dra',
        dstNum: 7,
      );
      // Walk both name tables in parallel.  Patched entries (the ones whose
      // string changed) must have hash=0 in `patched`, while the same entry
      // had a non-zero hash in `src` — confirms we're zeroing on patch hit
      // and only on patch hit.
      final namesPatched = _readNameTable(patched);
      final namesSrc = _readNameTable(src);
      expect(namesPatched.length, namesSrc.length);
      var anyPatchedZero = false;
      var anyUnpatchedKeptHash = false;
      for (var i = 0; i < namesPatched.length; i++) {
        final changed = namesPatched[i].$1 != namesSrc[i].$1;
        if (changed) {
          expect(namesPatched[i].$2, 0,
              reason: 'patched entry "${namesPatched[i].$1}" must have hash=0');
          if (namesSrc[i].$2 != 0) anyPatchedZero = true;
        } else {
          expect(namesPatched[i].$2, namesSrc[i].$2,
              reason: 'unpatched entry "${namesPatched[i].$1}" hash must match');
          if (namesSrc[i].$2 != 0) anyUnpatchedKeptHash = true;
        }
      }
      expect(anyPatchedZero, isTrue,
          reason: 'at least one entry should have been patched');
      expect(anyUnpatchedKeptHash, isTrue,
          reason: 'at least one entry should keep its original hash');
    });
  });

  group('patchLegacy2DigitUasset (input validation)', () {
    test('throws when src code length differs from dst code length', () {
      // Both folders must be `T_Bkg_<3char>`; different lengths → throws.
      // We don't need real data — the length check fires before any byte read.
      expect(
        () => patchLegacy2DigitUasset(
          srcData: Uint8List.fromList(const [0]),
          srcCode: 'Hor',
          srcNum: 1,
          dstCode: 'XX',
          dstNum: 1,
        ),
        throwsArgumentError,
      );
    });

    test('throws on out-of-range slot numbers (must be 1..99)', () {
      expect(
        () => patchLegacy2DigitUasset(
          srcData: Uint8List.fromList(const [0]),
          srcCode: 'Hor',
          srcNum: 100,
          dstCode: 'Sci',
          dstNum: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => patchLegacy2DigitUasset(
          srcData: Uint8List.fromList(const [0]),
          srcCode: 'Hor',
          srcNum: 1,
          dstCode: 'Sci',
          dstNum: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}

/// Helper: read each name-table entry's `(string, hash)`.  Returns an
/// empty list if the header looks malformed.
List<(String, int)> _readNameTable(List<int> data) {
  if (data.length < 0x24 + 4) return const [];
  final view = ByteData.sublistView(Uint8List.fromList(data));
  final pkgLen = view.getInt32(0x20, Endian.little);
  if (pkgLen <= 0 || 0x24 + pkgLen > data.length) return const [];
  final fse = 0x24 + pkgLen;
  if (fse + 12 > data.length) return const [];
  final nameCount = view.getInt32(fse + 4, Endian.little);
  final nameOffset = view.getInt32(fse + 8, Endian.little);
  final out = <(String, int)>[];
  var pos = nameOffset;
  for (var i = 0; i < nameCount; i++) {
    if (pos + 4 > data.length) break;
    final slen = view.getInt32(pos, Endian.little);
    if (slen <= 0 || slen > 500) break;
    if (pos + 4 + slen + 4 > data.length) break;
    // Strip trailing NUL.
    final s = String.fromCharCodes(data.sublist(pos + 4, pos + 4 + slen - 1));
    final h = view.getUint32(pos + 4 + slen, Endian.little);
    out.add((s, h));
    pos += 4 + slen + 4;
  }
  return out;
}

bool _containsAscii(List<int> haystack, String needle) {
  final n = needle.codeUnits;
  if (n.isEmpty) return true;
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}
