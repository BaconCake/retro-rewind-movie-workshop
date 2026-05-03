import 'dart:io';

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
