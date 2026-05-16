import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/standee_blueprint_cloner.dart';
import 'package:rr_movie_workshop/data/datatable/standee_mi_builder.dart';
import 'package:rr_movie_workshop/data/datatable/standee_templates.dart';
import 'package:rr_movie_workshop/data/datatable/standee_thumbnail_builder.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

/// Load the standee templates directly from `assets/standee_templates/`
/// so the unit tests don't need Flutter's rootBundle setup.  The build
/// pipeline still uses [StandeeTemplates.load] in production.
Future<StandeeTemplates> _loadTemplatesFromDisk() async {
  final base = p.join(Directory.current.path, 'assets', 'standee_templates');
  Future<Uint8List> read(String name) async {
    return await File(p.join(base, name)).readAsBytes();
  }

  return StandeeTemplates.fromBytes(
    miUasset: await read('mi_uasset.bin'),
    miUexp: await read('mi_uexp.bin'),
    thumbUasset: await read('thumb_uasset.bin'),
    thumbUexpHeader: await read('thumb_uexp_header.bin'),
    standeeFullresA: await read('standee_a.jpg'),
    standeeFullresB: await read('standee_b.jpg'),
    standeeFullresC: await read('standee_c.jpg'),
  );
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

void main() {
  group('StandeeMiBuilder (pure)', () {
    late StandeeMiBuilder builder;

    setUpAll(() async {
      builder = StandeeMiBuilder(await _loadTemplatesFromDisk());
    });

    test('decompressed MI templates have the documented sizes', () async {
      final t = await _loadTemplatesFromDisk();
      // Asserted by Python at RR_VHS_Tool.py:1171-1172.
      expect(t.miUasset.length, 1772);
      expect(t.miUexp.length, 33471);
    });

    test('build grows uasset by one byte per Hor_04 occurrence; uexp '
        'passes through unchanged', () async {
      final t = await _loadTemplatesFromDisk();
      final r = builder.build(genreCode: 'Sci', texNum: 7, standeeShape: 'C');
      // 3-digit migration (v1.8.2): "Hor_04" (6 chars) → "Sci_007" (7 chars)
      // grows the uasset by 1 byte per occurrence.  Other patches are
      // same-length.  PackageName also grows by 1.
      expect(r.totalShift, greaterThan(0));
      expect(r.uassetBytes.length, t.miUasset.length + r.totalShift);
      expect(r.uexpBytes, t.miUexp);
    });

    test('byte patches: target strings appear, source strings are gone',
        () async {
      final r = builder.build(genreCode: 'Sci', texNum: 7, standeeShape: 'C');

      // Source strings (from Hor_04, Standee A) should no longer appear.
      expect(_bytesContain(r.uassetBytes, 'Hor_04'.codeUnits), isFalse,
          reason: 'old genre+num leaked into output');
      expect(_bytesContain(r.uassetBytes, 'T_Bkg_Hor'.codeUnits), isFalse,
          reason: 'old folder leaked');
      expect(_bytesContain(r.uassetBytes, 'T_Standee_A_01_ao'.codeUnits),
          isFalse,
          reason: 'old AO texture leaked');

      // Target strings should be present (3-digit naming).
      expect(_bytesContain(r.uassetBytes, 'Sci_007'.codeUnits), isTrue);
      expect(_bytesContain(r.uassetBytes, 'T_Bkg_Sci'.codeUnits), isTrue);
      expect(_bytesContain(r.uassetBytes, 'T_Standee_C_01_ao'.codeUnits),
          isTrue);
    });

    test('patchedNames > 0 — at least one name-table entry got rewritten', () {
      final r = builder.build(genreCode: 'Dra', texNum: 1, standeeShape: 'B');
      expect(r.patchedNames, greaterThan(0));
    });

    test('relativePath follows the Python 3-digit convention', () {
      final r = builder.build(genreCode: 'Hor', texNum: 4, standeeShape: 'A');
      // texNum=4 with the Hor donor → "Hor_004" (3-digit), even though
      // donor template is "Hor_04".  Going from donor to target always
      // hits the rebuilder (Hor_04 → Hor_004 is a 6→7 char patch).
      expect(
          r.relativePath,
          'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/'
          'T_Bkg_Hor/MI_New_Hor_004');
    });

    test('rejects length-mismatched genre code', () {
      expect(
        () => builder.build(genreCode: 'XX', texNum: 1, standeeShape: 'A'),
        throwsA(isA<StandeeMiBuildError>()),
      );
    });

    test('rejects out-of-range tex_num (A3 — cap raised to 999)', () {
      // 1..kNrPerGenreCap (999) is now accepted; 1000+ rejected because
      // padLeft(3, '0') only fits 3 digits.
      expect(
        () => builder.build(genreCode: 'Dra', texNum: 1000, standeeShape: 'A'),
        throwsA(isA<StandeeMiBuildError>()),
      );
      expect(
        () => builder.build(genreCode: 'Dra', texNum: 0, standeeShape: 'A'),
        throwsA(isA<StandeeMiBuildError>()),
      );
      // 100 and 999 are now valid — used to throw pre-A3.
      expect(
        () => builder.build(genreCode: 'Dra', texNum: 100, standeeShape: 'A'),
        returnsNormally,
      );
      expect(
        () => builder.build(genreCode: 'Dra', texNum: 999, standeeShape: 'A'),
        returnsNormally,
      );
    });

    test('build is deterministic', () {
      final a = builder.build(genreCode: 'Pol', texNum: 1, standeeShape: 'A');
      final b = builder.build(genreCode: 'Pol', texNum: 1, standeeShape: 'A');
      expect(a.uassetBytes, b.uassetBytes);
      expect(a.uexpBytes, b.uexpBytes);
    });
  });

  group('StandeeThumbnailBuilder (fixture-based — needs texconv)', () {
    late AppConfig config;
    late StandeeTemplates templates;
    late bool fixturesAvailable;

    setUpAll(() async {
      final cfgPath = p.join(Directory.current.path, 'config.json');
      if (!File(cfgPath).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      final json = await JsonFileDataSource().readJson(cfgPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      config = ConfigDto.fromJson(json).toEntity();
      if (!File(config.texconv).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      templates = await _loadTemplatesFromDisk();
      fixturesAvailable = true;
    });

    test('builds a complete uasset+uexp pair', () async {
      if (!fixturesAvailable) {
        markTestSkipped('texconv unavailable');
        return;
      }
      final builder = StandeeThumbnailBuilder(templates, config);
      final r = await builder.build(sku: 51234, shape: 'A');

      // uexp = header (117) + pixel data (262144) + trailing (28) = 262289.
      expect(r.uexpBytes.length, 117 + 262144 + 28);
      expect(r.uassetBytes.length, templates.thumbUasset.length);
      expect(r.relativePath,
          'RetroRewind/Content/VideoStore/asset/prop/Standees/Thumbnail/'
          'T_Standees_Collection_51234');

      // The template SKU "12286" should be gone; "51234" present.
      expect(_bytesContain(r.uassetBytes, '12286'.codeUnits), isFalse);
      expect(_bytesContain(r.uassetBytes, '51234'.codeUnits), isTrue);
    });

    test('rejects non-5-digit SKU', () async {
      if (!fixturesAvailable) {
        markTestSkipped('texconv unavailable');
        return;
      }
      final builder = StandeeThumbnailBuilder(templates, config);
      expect(
        () => builder.build(sku: 1234, shape: 'A'),
        throwsA(isA<StandeeThumbnailBuildError>()
            .having((e) => e.code, 'code', 'E004')),
      );
      expect(
        () => builder.build(sku: 100000, shape: 'A'),
        throwsA(isA<StandeeThumbnailBuildError>()),
      );
    });
  });

  group('StandeeBlueprintCloner (fixture-based — needs base game pak)', () {
    late AppConfig config;
    late PakCache cache;
    late bool fixturesAvailable;

    setUpAll(() async {
      final cwd = Directory.current.path;
      final cfgPath = p.join(cwd, 'config.json');
      if (!File(cfgPath).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      final json = await JsonFileDataSource().readJson(cfgPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      config = ConfigDto.fromJson(json).toEntity();
      if (!File(config.repak).existsSync() ||
          !File(config.baseGamePak).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      cache = PakCache(cwd);
      fixturesAvailable = true;
    });

    test('clones blueprint and applies all v1.8.2 (3-digit) patches', () async {
      if (!fixturesAvailable) {
        markTestSkipped('base game pak unavailable');
        return;
      }
      final cloner = StandeeBlueprintCloner(cache);
      final r = await cloner.clone(
        config: config,
        sku: 51234,
        standeeShape: 'C',
        genreCode: 'Sci',
        texNum: 7,
      );

      // uexp FName-num: 2 occurrences of 10694 are uint32-replaced in place.
      expect(r.fnameNumReplacements, 2,
          reason: 'expected 2 occurrences of FName=10694 in uexp');
      // uasset: at least one name-table entry was rewritten (the MI ref
      // grew Dra_03→Sci_007 by 1 byte).  totalShift > 0 because of that.
      expect(r.patchedNames, greaterThan(0));
      expect(r.totalShift, greaterThan(0));

      // Source strings are gone, target strings present (3-digit naming).
      expect(_bytesContain(r.uassetBytes, '10693'.codeUnits), isFalse);
      expect(_bytesContain(r.uassetBytes, '51234'.codeUnits), isTrue);
      expect(_bytesContain(r.uassetBytes, 'LA_Standee_B_01'.codeUnits),
          isFalse);
      expect(_bytesContain(r.uassetBytes, 'LA_Standee_C_01'.codeUnits), isTrue);
      expect(_bytesContain(r.uassetBytes, 'MI_New_Dra_03'.codeUnits), isFalse);
      expect(_bytesContain(r.uassetBytes, 'MI_New_Sci_007'.codeUnits), isTrue);
      expect(_bytesContain(r.uassetBytes, 'T_Bkg_Dra'.codeUnits), isFalse);
      expect(_bytesContain(r.uassetBytes, 'T_Bkg_Sci'.codeUnits), isTrue);

      expect(r.relativePath,
          'RetroRewind/Content/VideoStore/asset/prop/Standees/'
          'mesh/Standees_Collection_51234');
    });

    test('rejects non-5-digit SKU', () async {
      if (!fixturesAvailable) {
        markTestSkipped('base game pak unavailable');
        return;
      }
      final cloner = StandeeBlueprintCloner(cache);
      expect(
        () => cloner.clone(
          config: config,
          sku: 999,
          standeeShape: 'A',
          genreCode: 'Dra',
          texNum: 1,
        ),
        throwsA(isA<StandeeBlueprintCloneError>()
            .having((e) => e.code, 'code', 'E004')),
      );
    });
  });
}
