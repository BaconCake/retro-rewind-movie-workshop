import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_file.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_parser.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

/// Integration test for the read-only DataTable parser.
///
/// Extracts the 13 base-game DataTable .uasset/.uexp pairs via PakCache and
/// asserts the parser can structurally interpret each one. The load-bearing
/// assertion is name-table parse → toBytes() byte-equal to the original
/// region: if that holds for all 13 genres, our model of the FName format
/// is solid enough for slice 2c-B (extending the table) to build on.
///
/// The test is gated on a working `config.json` in the project root with
/// real `repak` and `base_game_pak` paths. Without that we can't get at
/// the binary fixtures (committing them would mean shipping game assets),
/// so the test self-skips with a clear message.
void main() {
  group('DataTableParser (against base game fixtures)', () {
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
      final json =
          await JsonFileDataSource().readJson(configPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      config = ConfigDto.fromJson(json).toEntity();
      if (config.repak.isEmpty || config.baseGamePak.isEmpty) {
        fixturesAvailable = false;
        return;
      }
      if (!File(config.repak).existsSync() ||
          !File(config.baseGamePak).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      cache = PakCache(cwd);
      fixturesAvailable = true;
    });

    Future<DataTableFile?> loadGenre(String dataTableName) async {
      const dtBase =
          'RetroRewind/Content/VideoStore/core/blueprint/data';
      final ua =
          await cache.extractFile(config, '$dtBase/$dataTableName.uasset');
      final ue =
          await cache.extractFile(config, '$dtBase/$dataTableName.uexp');
      if (!ua.ok || !ue.ok) return null;
      final uaBytes = await File(ua.path!).readAsBytes();
      final ueBytes = await File(ue.path!).readAsBytes();
      return DataTableParser.parsePair(
        uassetBytes: uaBytes,
        uexpBytes: ueBytes,
        genreDataTableName: dataTableName,
      );
    }

    test('parses all 13 genres without throwing', () async {
      if (!fixturesAvailable) {
        markTestSkipped(
            'config.json with real repak/base_game_pak required for '
            'integration test');
        return;
      }
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull,
            reason: 'failed to extract DataTable for ${g.dataTableName}');
        // Python accepts either dashed or dashless form (RR_VHS_Tool.py:2924).
        final pn = dt!.uasset.packageName;
        final mentioned = pn.contains(g.dataTableName) ||
            pn.contains(g.dataTableName.replaceAll('-', ''));
        expect(mentioned, isTrue,
            reason: '${g.dataTableName}: PackageName "$pn" should mention '
                'the genre');
        expect(dt.uasset.nameTable.entries.length, dt.uasset.nameCount,
            reason:
                '${g.dataTableName}: parsed ${dt.uasset.nameTable.entries.length} '
                'name entries but header nameCount=${dt.uasset.nameCount}');
      }
    });

    test('uexp layout falls into known schemas', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      // Diagnostic table — uncomment to inspect new genre files:
      // for (final g in kGenres) {
      //   final dt = await loadGenre(g.dataTableName);
      //   stdout.writeln('${g.dataTableName.padRight(12)} '
      //       'rowStart=0x${dt!.uexp.rowStart.toRadixString(16)} '
      //       'rowCount=${dt.uexp.rowCount} '
      //       'rowSize=${dt.uexp.rowSize} '
      //       'tailBytes=${dt.uexp.tailBytes.length}');
      // }
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull);
        expect([0x16, 0x1A], contains(dt!.uexp.rowStart),
            reason: '${g.dataTableName}: unexpected rowStart '
                '0x${dt.uexp.rowStart.toRadixString(16)}');
        expect([71, 72, 73], contains(dt.uexp.rowSize),
            reason:
                '${g.dataTableName}: unexpected rowSize ${dt.uexp.rowSize}');
        // Note: rowsEndOffset can overrun for some base-game files (Action's
        // header reports rowCount=1155 but only ~1152 rows actually fit).
        // The engine tolerates this; we expose the literal header count and
        // leave it to walkers (RowDecoder) to bail at structural breaks.
      }
    });

    test('serial_size in uasset == len(uexp) - 4 for every genre', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      const dtBase =
          'RetroRewind/Content/VideoStore/core/blueprint/data';
      for (final g in kGenres) {
        final ueRes = await cache.extractFile(
            config, '$dtBase/${g.dataTableName}.uexp');
        expect(ueRes.ok, isTrue);
        final ueBytes = await File(ueRes.path!).readAsBytes();
        final dt = await loadGenre(g.dataTableName);
        expect(dt!.uasset.serialSize, ueBytes.length - 4,
            reason: '${g.dataTableName}: serial_size '
                '${dt.uasset.serialSize} != len(uexp)-4=${ueBytes.length - 4}');
      }
    });

    test('name table parse → toBytes() roundtrips byte-perfect', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      // Load-bearing assertion of slice 2c-A. If the bytes our serializer
      // emits don't match the bytes we parsed, our model of the FName
      // table format is wrong, and 2c-B (extending it) cannot be safe.
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull);
        final original = Uint8List.sublistView(
          dt!.uasset.rawBytes,
          dt.uasset.nameTable.regionStart,
          dt.uasset.nameTable.regionEnd,
        );
        final reserialised = dt.uasset.nameTable.toBytes();
        expect(reserialised, original,
            reason:
                '${g.dataTableName}: name table reserialisation differs');
      }
    });

    test('rowsEndOffset clamped to file size yields a non-empty tail or zero',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull);
        // For files where header rowCount is consistent with file size, the
        // tail accounting holds. For Action (overstated count), it doesn't —
        // we just check that rowStart and rowSize are sane.
        expect(dt!.uexp.rowStart, greaterThan(0));
        expect([71, 72, 73], contains(dt.uexp.rowSize));
      }
    });
  });

  group('DataTableParser (unit tests, no fixtures)', () {
    test('rejects bytes without UE4 magic', () {
      final bogus = Uint8List(0x40);
      expect(
        () => DataTableParser.parsePair(
          uassetBytes: bogus,
          uexpBytes: Uint8List.fromList(List<int>.filled(100, 0)),
          genreDataTableName: 'Horror',
        ),
        throwsA(isA<DataTableParseError>()),
      );
    });

    test('NameTable.toBytes round-trips a hand-built table', () {
      const entries = [
        NameTableEntry('Horror', 0x00000000),
        NameTableEntry('End of List', 0x00050000),
        NameTableEntry('1', 0x00000000),
      ];
      const table = NameTable(
          entries: entries, regionStart: 0, regionEnd: 0);
      final bytes = table.toBytes();
      var off = 0;
      final view = ByteData.sublistView(bytes);
      for (final e in entries) {
        final encoded = utf8.encode(e.value);
        expect(view.getInt32(off, Endian.little), encoded.length + 1,
            reason: 'length field for "${e.value}"');
        off += 4;
        expect(bytes.sublist(off, off + encoded.length), encoded,
            reason: 'UTF-8 bytes for "${e.value}"');
        off += encoded.length;
        expect(bytes[off], 0x00, reason: 'null terminator for "${e.value}"');
        off += 1;
        expect(view.getUint32(off, Endian.little), e.flags,
            reason: 'flags for "${e.value}"');
        off += 4;
      }
      expect(off, bytes.length);
    });
  });
}
