import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_builder.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_file.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_parser.dart';
import 'package:rr_movie_workshop/data/datatable/row_decoder.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

void main() {
  group('RowDecoder + DataTableBuilder (against base game fixtures)', () {
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

    test('decodes plausible slot counts for every genre', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      // The base-game DataTable per genre defines visible movies, which is
      // not the same as `bkgCount` (which counts T_Bkg textures available).
      // Action ships with only ~2 actual slots even though 15 textures
      // exist. For the test we just check that decoding yields *some* slots
      // (≥1) bounded above by the texture count, with sane structure.
      const root = kDataTableRootPath;
      for (final g in kGenres) {
        final ua = await cache.readFile(config, '$root/${g.dataTableName}.uasset');
        final ue = await cache.readFile(config, '$root/${g.dataTableName}.uexp');
        final dt = DataTableParser.parsePair(
          uassetBytes: ua!,
          uexpBytes: ue!,
          genreDataTableName: g.dataTableName,
        );
        final slots = RowDecoder.decodeBaseSlots(dt.uexp, dt.uasset.nameTable);
        expect(slots, isNotEmpty,
            reason: '${g.dataTableName}: decoded zero slots');
        expect(slots.length, lessThanOrEqualTo(g.bkgCount),
            reason: '${g.dataTableName}: decoded ${slots.length} > '
                'bkgCount ${g.bkgCount}');
        expect(slots.first.pnName, isNotEmpty);
        expect(slots.first.sku, greaterThan(0));
        expect(slots.first.bkgTex, startsWith('T_Bkg_${g.code}_'));
      }
    });

    test('DataTableBuilder produces structurally valid output', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = DataTableBuilder(cache);
      // Pick three genres covering all three schemas: Horror (V2), Police
      // (V3), Western (V1). If any throws or yields garbage bytes, the
      // pipeline is broken before we even ship to repak.
      const targets = ['Horror', 'Police', 'Western'];
      for (final dt in targets) {
        final r = await builder.build(config, dt);
        expect(r.uassetBytes.length, greaterThan(0x100));
        expect(r.uexpBytes.length, greaterThan(40));

        // Tail of the new uexp must be PLAIN_FOOTER exactly.
        final tail = r.uexpBytes.sublist(r.uexpBytes.length - 8);
        expect(tail, UExp.plainFooter,
            reason: '$dt: uexp does not end with PLAIN_FOOTER');

        // serial_size formula for builder output (which writes only the
        // 8-byte PLAIN_FOOTER after rows): rowStart + rowBlockLen − 4 =
        // len(uexp) − 12. The engine uses this to compute its expected
        // total before a TArray resize; mismatch crashes loading.
        final reparse = DataTableParser.parsePair(
          uassetBytes: r.uassetBytes,
          uexpBytes: r.uexpBytes,
          genreDataTableName: dt,
        );
        expect(reparse.uasset.serialSize, r.uexpBytes.length - 12,
            reason:
                '$dt: serial_size ${reparse.uasset.serialSize} != len(uexp)-12 '
                '${r.uexpBytes.length - 12}');

        // Row count = real slots + 1 sentinel.
        expect(reparse.uexp.rowCount, r.slotCount + 1,
            reason:
                '$dt: rowCount ${reparse.uexp.rowCount} != slotCount+1 '
                '${r.slotCount + 1}');

        // Each row's start must hold the genre's RK_NUM. Walk via the
        // row block (variable-size aware): rowStart, advance by reading
        // each row's BI length to compute its size.
        var pos = reparse.uexp.rowStart;
        final view = ByteData.sublistView(r.uexpBytes);
        for (var n = 0; n < reparse.uexp.rowCount; n++) {
          expect(view.getUint32(pos + 4, Endian.little),
              reparse.uexp.rowKeyNumber,
              reason: '$dt: row $n at $pos missing RK_NUM');
          // Compute this row's size from its BI length so we handle 2/3-digit.
          final biLen = view.getInt32(pos + 29, Endian.little);
          // Schema-aware tail size after the BI string.
          final tailSize = switch (reparse.uexp.schema) {
            RowSchema.v1 => 25,
            RowSchema.v2 => 26,
            RowSchema.v3 => 27,
          };
          pos += 33 + biLen + tailSize;
        }
        // After walking all rows we land exactly on PLAIN_FOOTER.
        expect(pos, r.uexpBytes.length - 8,
            reason: '$dt: row walk landed at $pos, '
                'expected ${r.uexpBytes.length - 8}');
      }
    });

    test('title override is reflected in the rebuilt name table', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final builder = DataTableBuilder(cache);
      // Decode Horror's base slots to get a real pn_name to override.
      final ua =
          await cache.readFile(config, '$kDataTableRootPath/Horror.uasset');
      final ue =
          await cache.readFile(config, '$kDataTableRootPath/Horror.uexp');
      final base = DataTableParser.parsePair(
        uassetBytes: ua!,
        uexpBytes: ue!,
        genreDataTableName: 'Horror',
      );
      final slots = RowDecoder.decodeBaseSlots(base.uexp, base.uasset.nameTable);
      final originalTitle = slots.first.pnName;

      const replacement = 'rr_movie_workshop_test_replacement';
      final r = await builder.build(
        config,
        'Horror',
        titleOverrides: {originalTitle: replacement},
      );

      // The replacement string must appear in the rebuilt uasset's name
      // table; the original must NOT (we're the only slot using that title).
      // Note: if more than one slot shares the title, the original may
      // still appear — relax this branch by counting occurrences instead.
      final reparse = DataTableParser.parsePair(
        uassetBytes: r.uassetBytes,
        uexpBytes: r.uexpBytes,
        genreDataTableName: 'Horror',
      );
      final names =
          reparse.uasset.nameTable.entries.map((e) => e.value).toList();
      expect(names, contains(replacement),
          reason: 'replacement title not present in rebuilt name table');
      // The original title stays in the rebuilt name table because we
      // *extend*, never *prune*: the base-game name table is preserved and
      // only the row references swap from idx(originalTitle) to
      // idx(replacement). That's harmless — unreferenced FName entries
      // don't affect runtime behaviour.
      expect(names, contains(originalTitle),
          reason: 'base name table is preserved on extend; '
              'original title should still be present');
    });
  });
}
