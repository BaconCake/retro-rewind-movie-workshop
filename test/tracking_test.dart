import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/tracking_set_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';
import 'package:rr_movie_workshop/domain/tracking.dart';

SlotData _slot(String bkgTex) => SlotData(
      bkgTex: bkgTex,
      pnName: 'Title',
      ls: 0,
      lsc: 0,
      sku: 0,
      ntu: false,
    );

NewReleaseSlot _nr(int sku) => NewReleaseSlot(
      title: 'Title',
      genre: 'Drama',
      genreCode: 'Dra',
      genreByte: 4,
      bkgTex: 'T_New_Dra_005',
      sku: sku,
      standeeShape: 'A',
      texNum: 5,
    );

void main() {
  group('stable key helpers', () {
    test('genreSlotKey returns the slot bkgTex verbatim', () {
      expect(genreSlotKey(_slot('T_Bkg_Dra_005')), 'T_Bkg_Dra_005');
    });

    test('nrSlotKey returns "NR_<sku>" — stable across genre changes', () {
      expect(nrSlotKey(_nr(58004)), 'NR_58004');
    });
  });

  group('validTrackingKeys', () {
    test('union of genre bkgTexes + NR_<sku> across genres', () {
      final keys = validTrackingKeys(
        genreSlotsByGenre: {
          'Drama': [_slot('T_Bkg_Dra_001'), _slot('T_Bkg_Dra_002')],
          'Horror': [_slot('T_Bkg_Hor_001')],
        },
        nrs: [_nr(58004), _nr(58005)],
      );
      expect(keys, {
        'T_Bkg_Dra_001',
        'T_Bkg_Dra_002',
        'T_Bkg_Hor_001',
        'NR_58004',
        'NR_58005',
      });
    });

    test('empty inputs yield empty set', () {
      expect(
        validTrackingKeys(genreSlotsByGenre: {}, nrs: []),
        isEmpty,
      );
    });
  });

  group('pruneOrphans', () {
    test('drops keys not in valid set, returns the dropped list', () {
      final r = pruneOrphans(
        {'T_Bkg_Dra_001', 'NR_58004', 'T_Bkg_Old_999', 'NR_99999'},
        {'T_Bkg_Dra_001', 'NR_58004'},
      );
      expect(r.pruned, {'T_Bkg_Dra_001', 'NR_58004'});
      expect(r.dropped, {'T_Bkg_Old_999', 'NR_99999'});
    });

    test('no orphans → returns same instance, empty dropped', () {
      final input = {'T_Bkg_Dra_001', 'NR_58004'};
      final r = pruneOrphans(input, {'T_Bkg_Dra_001', 'NR_58004'});
      expect(r.dropped, isEmpty);
      expect(identical(r.pruned, input), isTrue,
          reason: 'fast-path returns the original set when nothing changed');
    });

    test('all orphans → empty pruned, all dropped', () {
      final r = pruneOrphans(
        {'a', 'b', 'c'},
        {'x', 'y'},
      );
      expect(r.pruned, isEmpty);
      expect(r.dropped, {'a', 'b', 'c'});
    });

    test('empty tracked → empty pruned, empty dropped', () {
      final r = pruneOrphans(<String>{}, {'a', 'b'});
      expect(r.pruned, isEmpty);
      expect(r.dropped, isEmpty);
    });
  });

  group('TrackingSetDataSource (JSON round-trip)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tracking_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('load returns empty set when file is missing', () async {
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      expect(await ds.load(), isEmpty);
    });

    test('save writes a sorted JSON array (Python parity)', () async {
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      await ds.save({'NR_58004', 'T_Bkg_Dra_002', 'T_Bkg_Dra_001'});
      final raw = await File(p.join(tmp.path, 'edited_slots.json'))
          .readAsString();
      expect(raw, '["NR_58004","T_Bkg_Dra_001","T_Bkg_Dra_002"]');
    });

    test('round-trip preserves set contents', () async {
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'shipped_slots.json');
      final original = {'T_Bkg_Hor_001', 'NR_58005', 'T_Bkg_Dra_001'};
      await ds.save(original);
      final loaded = await ds.load();
      expect(loaded, original);
    });

    test('load skips non-string entries (defensive)', () async {
      final f = File(p.join(tmp.path, 'edited_slots.json'));
      await f.writeAsString('["a", 42, "b", null, "c"]');
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      expect(await ds.load(), {'a', 'b', 'c'});
    });

    test('load returns empty for malformed JSON', () async {
      final f = File(p.join(tmp.path, 'edited_slots.json'));
      await f.writeAsString('{"not": "a list"}');
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      expect(await ds.load(), isEmpty);
    });

    test('delete removes the file (Python clear_edited_slots parity)',
        () async {
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      await ds.save({'a', 'b'});
      expect(await File(p.join(tmp.path, 'edited_slots.json')).exists(),
          isTrue);
      await ds.delete();
      expect(await File(p.join(tmp.path, 'edited_slots.json')).exists(),
          isFalse);
    });

    test('delete is idempotent when file is missing', () async {
      final ds = TrackingSetDataSource(
          workingDir: tmp.path, fileName: 'edited_slots.json');
      await ds.delete(); // must not throw
    });
  });
}
