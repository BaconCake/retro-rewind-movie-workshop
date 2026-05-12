import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';
import 'package:rr_movie_workshop/domain/sort.dart';

SlotData _slot(String bkgTex, {String pnName = ''}) => SlotData(
      bkgTex: bkgTex,
      pnName: pnName,
      ls: 0,
      lsc: 0,
      sku: 0,
      isNewToUnlock: false,
    );

NewReleaseSlot _nr({
  required String title,
  required String genre,
  String genreCode = 'Xxx',
  int genreByte = 0,
  required int texNum,
  required int sku,
  String? createdAt,
  String? lastEditedAt,
}) =>
    NewReleaseSlot(
      title: title,
      genre: genre,
      genreCode: genreCode,
      genreByte: genreByte,
      bkgTex: 'T_New_${genreCode}_${texNum.toString().padLeft(3, '0')}',
      sku: sku,
      standeeShape: 'A',
      texNum: texNum,
      createdAt: createdAt,
      lastEditedAt: lastEditedAt,
    );

void main() {
  group('SortKey wire-format round-trip', () {
    test('every enum value maps back from its wire key', () {
      for (final k in SortKey.values) {
        expect(SortKey.fromWireKey(k.wireKey), k);
      }
    });

    test('unknown / null key falls back to default', () {
      expect(SortKey.fromWireKey(null), kDefaultSortKey);
      expect(SortKey.fromWireKey('zzz_unknown'), kDefaultSortKey);
    });

    test('default is created_asc (legacy oldest-first order)', () {
      expect(kDefaultSortKey, SortKey.createdAsc);
    });
  });

  group('sortSlots — name', () {
    test('asc orders case-insensitive alphabetically', () {
      final out = sortSlots([
        _slot('a', pnName: 'Zelda'),
        _slot('b', pnName: 'abba'),
        _slot('c', pnName: 'Mario'),
      ], SortKey.nameAsc);
      expect(out.map((s) => s.pnName).toList(),
          ['abba', 'Mario', 'Zelda']);
    });

    test('desc reverses', () {
      final out = sortSlots([
        _slot('a', pnName: 'Zelda'),
        _slot('b', pnName: 'abba'),
        _slot('c', pnName: 'Mario'),
      ], SortKey.nameDesc);
      expect(out.map((s) => s.pnName).toList(),
          ['Zelda', 'Mario', 'abba']);
    });

    test('identical titles preserve original insert order (stable)', () {
      final out = sortSlots([
        _slot('a', pnName: 'Same'),
        _slot('b', pnName: 'Same'),
        _slot('c', pnName: 'Same'),
      ], SortKey.nameAsc);
      expect(out.map((s) => s.bkgTex).toList(), ['a', 'b', 'c']);
    });
  });

  group('sortSlots — date with no timestamps (today\'s SlotData)', () {
    test('date_asc falls back to original index (legacy order)', () {
      // SlotData has no timestamps yet; every slot lands in the no-ts
      // bucket which sorts by original index.  Asc preserves the input
      // order — that's why the legacy library doesn't visually shift
      // when sort defaults to created_asc.
      final input = [
        _slot('a', pnName: 'Z'),
        _slot('b', pnName: 'A'),
        _slot('c', pnName: 'M'),
      ];
      final out = sortSlots(input, SortKey.createdAsc);
      expect(out.map((s) => s.bkgTex).toList(), ['a', 'b', 'c']);
    });

    test('date_desc reverses fallback order', () {
      final input = [
        _slot('a'),
        _slot('b'),
        _slot('c'),
      ];
      final out = sortSlots(input, SortKey.createdDesc);
      expect(out.map((s) => s.bkgTex).toList(), ['c', 'b', 'a']);
    });
  });

  group('sortNrSlots — name', () {
    test('case-insensitive, stable by genre then tex_num', () {
      final out = sortNrSlots([
        _nr(title: 'Bravo', genre: 'Drama', texNum: 1, sku: 1),
        _nr(title: 'alpha', genre: 'Horror', texNum: 1, sku: 2),
        _nr(title: 'alpha', genre: 'Drama', texNum: 2, sku: 3),
      ], SortKey.nameAsc);
      expect(out.map((n) => n.sku).toList(), [3, 2, 1],
          reason: 'alpha/Drama before alpha/Horror (genre rank), '
              'Bravo last');
    });
  });

  group('sortNrSlots — date timestamps', () {
    test('with-timestamp entries come before no-timestamp in both directions',
        () {
      final out = sortNrSlots([
        _nr(title: 'A', genre: 'Drama', texNum: 1, sku: 1), // no ts
        _nr(
            title: 'B',
            genre: 'Drama',
            texNum: 2,
            sku: 2,
            createdAt: '2026-01-01T00:00:00'),
        _nr(title: 'C', genre: 'Drama', texNum: 3, sku: 3), // no ts
        _nr(
            title: 'D',
            genre: 'Drama',
            texNum: 4,
            sku: 4,
            createdAt: '2026-03-01T00:00:00'),
      ], SortKey.createdAsc);
      expect(out.take(2).map((n) => n.sku).toList(), [2, 4],
          reason: 'with-ts first, oldest first within bucket');
      expect(out.skip(2).map((n) => n.sku).toList(), [1, 3],
          reason: 'no-ts after, ordered by tex_num');
    });

    test('descending flips within-bucket but not between buckets', () {
      final out = sortNrSlots([
        _nr(title: 'A', genre: 'Drama', texNum: 1, sku: 1), // no ts
        _nr(
            title: 'B',
            genre: 'Drama',
            texNum: 2,
            sku: 2,
            createdAt: '2026-01-01T00:00:00'),
        _nr(
            title: 'D',
            genre: 'Drama',
            texNum: 4,
            sku: 4,
            createdAt: '2026-03-01T00:00:00'),
      ], SortKey.createdDesc);
      expect(out.first.sku, 4,
          reason: 'newest with-ts first (desc within bucket)');
      expect(out.last.sku, 1,
          reason: 'no-ts entry stays last regardless of direction');
    });

    test('no-ts fallback uses (genre rank, tex_num)', () {
      // Action=0, Adult=1, Adventure=2, Comedy=3, Drama=4, Fantasy=5,
      // Horror=6, Kids=7, ... per kGenres.  Without timestamps, NRs
      // should cluster by genre tab order, then tex_num within.
      final out = sortNrSlots([
        _nr(title: 'd1', genre: 'Drama', texNum: 1, sku: 1),
        _nr(title: 'c1', genre: 'Comedy', texNum: 1, sku: 2),
        _nr(title: 'h2', genre: 'Horror', texNum: 2, sku: 3),
        _nr(title: 'd2', genre: 'Drama', texNum: 2, sku: 4),
        _nr(title: 'c2', genre: 'Comedy', texNum: 2, sku: 5),
      ], SortKey.createdAsc);
      expect(
        out.map((n) => n.genre).toList(),
        ['Comedy', 'Comedy', 'Drama', 'Drama', 'Horror'],
        reason: 'genre tab order, then tex_num inside each genre',
      );
    });
  });
}
