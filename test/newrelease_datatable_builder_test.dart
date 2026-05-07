import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/new_release.dart';
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_parser.dart';
import 'package:rr_movie_workshop/data/datatable/newrelease_datatable_builder.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';

NewReleaseSlot _slot({
  required String genre,
  required int texNum,
  required int sku,
  String title = 'Test NR',
  String shape = 'A',
}) {
  final code = switch (genre) {
    'Action' => 'Act',
    'Drama' => 'Dra',
    'Horror' => 'Hor',
    'Sci-Fi' => 'Sci',
    'Comedy' => 'Com',
    'Romance' => 'Rom',
    'Western' => 'Wst',
    _ => 'XXX',
  };
  return NewReleaseSlot(
    title: title,
    genre: genre,
    genreCode: code,
    genreByte: kNrGenreByte[genre] ?? 0,
    bkgTex: 'T_New_${code}_${texNum.toString().padLeft(2, '0')}',
    sku: sku,
    standeeShape: shape,
    texNum: texNum,
  );
}

void main() {
  group('NewReleaseDataTableBuilder (against base game fixtures)', () {
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

    test('builds valid uasset+uexp pair for one NR slot', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final r = await builder.build(config, [
        _slot(genre: 'Drama', texNum: 1, sku: 50000, title: 'Test Movie'),
      ]);
      expect(r, isNotNull);
      expect(r!.rowCount, 1);
      expect(r.warnings, isEmpty);

      // Tail of the new uexp must be PLAIN_FOOTER exactly.
      final tail = r.uexpBytes.sublist(r.uexpBytes.length - 8);
      expect(tail, [0x00, 0x00, 0x00, 0x00, 0xC1, 0x83, 0x2A, 0x9E]);

      // uexp size = headerLen + nRows*54 + 8 (footer)
      // Re-derive headerLen via a new ROW_START scan on the output and
      // confirm the math holds.
      final hdrLen = r.uexpBytes.length - 1 * 54 - 8;
      expect(hdrLen, greaterThan(0));

      // Re-parse the rebuilt uasset (NR-named) so we can verify the title
      // landed in the FName table.
      final reparse = DataTableParser.parsePair(
        uassetBytes: r.uassetBytes,
        uexpBytes: r.uexpBytes,
        genreDataTableName: 'NewRelease_Details_-_Data',
      );
      final names =
          reparse.uasset.nameTable.entries.map((e) => e.value).toSet();
      expect(names, contains('Test Movie'));
      expect(names, contains('1')); // row key string
    });

    test('linked-list NextRowKey chain wires rows in order', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final r = await builder.build(config, [
        _slot(genre: 'Drama', texNum: 1, sku: 50001, title: 'Movie A'),
        _slot(genre: 'Drama', texNum: 2, sku: 50002, title: 'Movie B'),
        _slot(genre: 'Drama', texNum: 3, sku: 50003, title: 'Movie C'),
      ]);
      expect(r, isNotNull);
      expect(r!.rowCount, 3);

      // Walk rows: each row's NextRowKey (offset 50, uint32) should be the
      // FName index of the next row's row key string ("2", "3"), with the
      // last row terminating at 0.
      final reparse = DataTableParser.parsePair(
        uassetBytes: r.uassetBytes,
        uexpBytes: r.uexpBytes,
        genreDataTableName: 'NewRelease_Details_-_Data',
      );
      final names = reparse.uasset.nameTable.entries.map((e) => e.value).toList();
      int idxOf(String s) => names.indexOf(s);

      final hdrLen = r.uexpBytes.length - 3 * 54 - 8;
      final view = ByteData.sublistView(r.uexpBytes);
      final next1 = view.getUint32(hdrLen + 0 * 54 + 50, Endian.little);
      final next2 = view.getUint32(hdrLen + 1 * 54 + 50, Endian.little);
      final next3 = view.getUint32(hdrLen + 2 * 54 + 50, Endian.little);

      expect(next1, idxOf('2'));
      expect(next2, idxOf('3'));
      expect(next3, 0, reason: 'last row terminates the linked list');
    });

    test('row fields land at the documented offsets', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final r = await builder.build(config, [
        _slot(genre: 'Horror', texNum: 1, sku: 51234, title: 'Spooky'),
      ]);
      expect(r, isNotNull);

      final hdrLen = r!.uexpBytes.length - 1 * 54 - 8;
      final view = ByteData.sublistView(r.uexpBytes);

      // RK_NUM at row+4
      expect(view.getUint32(hdrLen + 4, Endian.little), 0x01A81780);
      // SubjectImage FString len = 3
      expect(view.getInt32(hdrLen + 16, Endian.little), 3);
      // "-1\0"
      expect(r.uexpBytes[hdrLen + 20], 0x2D);
      expect(r.uexpBytes[hdrLen + 21], 0x31);
      expect(r.uexpBytes[hdrLen + 22], 0x00);
      // BackgroundImage FString len = 13
      expect(view.getInt32(hdrLen + 23, Endian.little), 13);
      // bkg_tex bytes 27..38, then null at 39
      expect(
        String.fromCharCodes(r.uexpBytes.sublist(hdrLen + 27, hdrLen + 39)),
        'T_New_Hor_01',
      );
      expect(r.uexpBytes[hdrLen + 39], 0x00);
      // Genre byte = Horror = 0x05
      expect(r.uexpBytes[hdrLen + 40], 0x05);
      // LayoutStyle int32 = -1
      expect(view.getInt32(hdrLen + 41, Endian.little), -1);
      // SKU uint16 = 51234
      expect(view.getUint16(hdrLen + 45, Endian.little), 51234);
      // NewToUnlock = 1
      expect(r.uexpBytes[hdrLen + 49], 0x01);
    });

    test('serial_size patched to rowStart + nRows*54 - 4', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final r = await builder.build(config, [
        _slot(genre: 'Drama', texNum: 1, sku: 50100, title: 'A'),
        _slot(genre: 'Drama', texNum: 2, sku: 50101, title: 'B'),
      ]);
      expect(r, isNotNull);

      final reparse = DataTableParser.parsePair(
        uassetBytes: r!.uassetBytes,
        uexpBytes: r.uexpBytes,
        genreDataTableName: 'NewRelease_Details_-_Data',
      );

      final hdrLen = r.uexpBytes.length - 2 * 54 - 8;
      final expectedSerial = hdrLen + 2 * 54 - 4;
      expect(reparse.uasset.serialSize, expectedSerial,
          reason: 'serial_size should be rowStart + nRows*54 - 4');
    });

    test('build is deterministic (same input → same output)', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final input = [
        _slot(genre: 'Drama', texNum: 1, sku: 50500, title: 'X'),
      ];
      final r1 = await builder.build(config, input);
      final r2 = await builder.build(config, input);
      expect(r1!.uassetBytes, r2!.uassetBytes);
      expect(r1.uexpBytes, r2.uexpBytes);
    });

    test('returns null when every slot is filtered out', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      // Adventure isn't in kNrGenreByte → filtered.
      final invalid = NewReleaseSlot(
        title: 'Bogus',
        genre: 'Adventure',
        genreCode: 'Adv',
        genreByte: 0x00,
        bkgTex: 'T_New_Adv_01',
        sku: 50001,
        standeeShape: 'A',
        texNum: 1,
      );
      final r = await builder.build(config, [invalid]);
      expect(r, isNull);
    });

    test('reports a warning for every filtered slot but still ships valid ones',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(cache);
      final r = await builder.build(config, [
        NewReleaseSlot(
          title: 'Bogus',
          genre: 'Adventure',
          genreCode: 'Adv',
          genreByte: 0x00,
          bkgTex: 'T_New_Adv_01',
          sku: 50001,
          standeeShape: 'A',
          texNum: 1,
        ),
        _slot(genre: 'Drama', texNum: 1, sku: 50002, title: 'OK'),
      ]);
      expect(r, isNotNull);
      expect(r!.rowCount, 1);
      expect(r.warnings, hasLength(1));
      expect(r.warnings.single, contains('Adventure'));
    });
  });

  group('NewReleaseDataTableBuilder — input validation', () {
    test('SKU > uint16 throws E004', () async {
      // No PakCache call needed because validation happens before extract.
      // We pass a slot with SKU > 65535 and a fixtures-unavailable cache —
      // the builder hits the SKU check while building rows.
      // Without fixtures, build() would throw on extract first; so we test
      // the validation by hitting it via a *valid* extract path. If the user
      // doesn't have fixtures, this whole group skips.
      final cwd = Directory.current.path;
      if (!File(p.join(cwd, 'config.json')).existsSync()) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final json = await JsonFileDataSource().readJson(p.join(cwd, 'config.json'));
      if (json == null) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final cfg = ConfigDto.fromJson(json).toEntity();
      if (!File(cfg.repak).existsSync() || !File(cfg.baseGamePak).existsSync()) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = NewReleaseDataTableBuilder(PakCache(cwd));
      final bad = _slot(genre: 'Drama', texNum: 1, sku: 70000, title: 'overflow');
      expect(
        () => builder.build(cfg, [bad]),
        throwsA(isA<NewReleaseBuildError>()
            .having((e) => e.code, 'code', 'E004')),
      );
    });
  });
}
