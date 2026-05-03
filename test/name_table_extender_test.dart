import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_file.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_parser.dart';
import 'package:rr_movie_workshop/data/datatable/name_table_extender.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

/// Tests the byte-level name-table extender against the same 13 base-game
/// DataTables that 2c-A's parser locked down. Two assertions matter most:
///
///   1. Zero-append must produce the original bytes verbatim. If the extender
///      changes anything when there are no new entries, header rewriting is
///      buggy.
///   2. After appending entries, re-parsing the new uasset (with a synthetic
///      uexp the same size as the original) must yield exactly the new
///      [originalEntries + appended] table — proving prefix, splice, and
///      header patching are all consistent.
void main() {
  group('NameTableExtender (against base game fixtures)', () {
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

    test('zero-append returns the original bytes verbatim', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull);
        final ext = NameTableExtender(dt!.uasset);
        expect(ext.newEntryCount, 0);
        expect(ext.growthBytes, 0);
        final out = ext.buildUAssetBytes();
        expect(out, dt.uasset.rawBytes,
            reason: '${g.dataTableName}: zero-append produced different bytes');
      }
    });

    test('indexOf is idempotent on existing entries', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final dt = await loadGenre('Horror');
      expect(dt, isNotNull);
      final ext = NameTableExtender(dt!.uasset);
      // Pick three names that are guaranteed to already exist in the base
      // Horror name table.
      final existing = dt.uasset.nameTable.entries.first.value;
      final idx1 = ext.indexOf(existing);
      final idx2 = ext.indexOf(existing);
      expect(idx1, idx2, reason: 'idempotent lookup should return same index');
      expect(ext.newEntryCount, 0,
          reason: 'looking up existing names must not append');
    });

    test('one-append: prefix preserved, splice present, header bumped',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      final dt = await loadGenre('Horror');
      expect(dt, isNotNull);
      final ext = NameTableExtender(dt!.uasset);
      final newIdx = ext.indexOf('rr_movie_workshop_test_entry');
      expect(newIdx, dt.uasset.nameTable.entries.length,
          reason: 'first append should land at original entry count');
      expect(ext.newEntryCount, 1);
      final shift = ext.growthBytes;
      expect(shift, greaterThan(0));

      final out = ext.buildUAssetBytes();
      expect(out.length, dt.uasset.rawBytes.length + shift);

      // The inserted bytes [regionEnd, regionEnd+shift) must be exactly the
      // serialized new entries. This proves the splice is correct and the
      // entry encoder agrees with the parser's expected format.
      final regionEnd = dt.uasset.nameTable.regionEnd;
      // Reconstruct what we expect at the splice: a NameTable containing
      // just the new entries, serialised.
      const newEntry =
          NameTableEntry('rr_movie_workshop_test_entry', 0);
      final spliceExpected =
          NameTable(entries: const [newEntry], regionStart: 0, regionEnd: 0)
              .toBytes();
      expect(
        Uint8List.sublistView(out, regionEnd, regionEnd + shift),
        spliceExpected,
        reason: 'inserted bytes must equal serialised new entries',
      );

      // Bytes after the splice [regionEnd+shift, end) come from the original
      // suffix [regionEnd, end), with a small set of header fields patched
      // (TotalHeaderSize, NameCount, FSE_OFFSET_FIELDS, int64 file-size refs).
      // We don't check byte equality of suffix — that's the point of the
      // re-parse below. We DO check the suffix length is right.
      expect(out.length - (regionEnd + shift),
          dt.uasset.rawBytes.length - regionEnd,
          reason: 'suffix length should match the original post-name-table');

      final fakeUexp = Uint8List(dt.uasset.serialSize + 4);
      final reparse = DataTableParser.parsePair(
        uassetBytes: out,
        uexpBytes: fakeUexp,
        genreDataTableName: 'Horror',
      );
      expect(reparse.uasset.nameCount, dt.uasset.nameCount + 1);
      expect(reparse.uasset.nameTable.entries.length, dt.uasset.nameCount + 1);
      expect(reparse.uasset.nameTable.entries.last.value,
          'rr_movie_workshop_test_entry');
      // Offsets must have shifted forward by exactly `shift`.
      expect(reparse.uasset.nameOffset, dt.uasset.nameOffset);
      expect(reparse.uasset.exportOffset, dt.uasset.exportOffset + shift);
      expect(reparse.uasset.serialSizeOffset,
          dt.uasset.serialSizeOffset + shift);
      // Serial size value (= len(uexp) - 4) is unchanged because the uexp
      // didn't change.
      expect(reparse.uasset.serialSize, dt.uasset.serialSize);
    });

    test('multi-append: all 13 genres re-parse with extended table', () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      // Append a varied set: a row-key string, a movie title, the sentinel.
      const adds = ['1', '2', '3', 'rr_test_title', 'End of List'];
      for (final g in kGenres) {
        final dt = await loadGenre(g.dataTableName);
        expect(dt, isNotNull);
        final ext = NameTableExtender(dt!.uasset);
        final originalCount = dt.uasset.nameTable.entries.length;
        for (final s in adds) {
          ext.indexOf(s);
        }
        // Some of `adds` may already exist in this genre; new entries are
        // exactly those that weren't already present.
        final originalSet =
            dt.uasset.nameTable.entries.map((e) => e.value).toSet();
        final addedHere = adds.where((s) => !originalSet.contains(s)).toList();
        expect(ext.newEntryCount, addedHere.length,
            reason: '${g.dataTableName}: newEntryCount mismatch');

        final out = ext.buildUAssetBytes();
        final fakeUexp = Uint8List(dt.uasset.serialSize + 4);
        final reparse = DataTableParser.parsePair(
          uassetBytes: out,
          uexpBytes: fakeUexp,
          genreDataTableName: g.dataTableName,
        );
        expect(reparse.uasset.nameCount, originalCount + addedHere.length,
            reason: '${g.dataTableName}: reparse name count wrong');
        // Each appended-to-this-genre entry must now be findable.
        final reparseSet =
            reparse.uasset.nameTable.entries.map((e) => e.value).toSet();
        for (final s in addedHere) {
          expect(reparseSet.contains(s), isTrue,
              reason: '${g.dataTableName}: appended "$s" missing after reparse');
        }
      }
    });
  });

  group('NameTableExtender (no fixtures)', () {
    test('growthBytes accounts for UTF-8 byte length, not character count',
        () {
      // Build a tiny synthetic UAsset that the extender can wrap. We don't
      // need a valid file for this — just an empty NameTable + zero-length
      // raw bytes — because we only test the growth accounting logic.
      final empty = UAsset(
        rawBytes: Uint8List(0),
        packageName: '',
        packageNameLengthOffset: 0,
        packageSummaryOffset: 0,
        nameCount: 0,
        nameOffset: 0,
        exportOffset: 0,
        serialSizeOffset: 0,
        serialSize: 0,
        nameTable: const NameTable(
            entries: [], regionStart: 0, regionEnd: 0),
      );
      final ext = NameTableExtender(empty);
      ext.indexOf('A'); // 1 utf8 byte → 4+1+1+4 = 10
      ext.indexOf('München'); // 8 utf8 bytes (umlaut = 2) → 4+8+1+4 = 17
      expect(ext.growthBytes, 10 + 17);
    });
  });
}
