import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/new_release.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';
import 'package:rr_movie_workshop/domain/nr_slot_logic.dart';

NewReleaseSlot _slot({
  required String genre,
  required int texNum,
  int sku = 50000,
  String shape = 'A',
  int? genreByte,
}) {
  return NewReleaseSlot(
    title: 'NR $genre $texNum',
    genre: genre,
    genreCode: 'XXX',
    genreByte: genreByte ?? kNrGenreByte[genre]!,
    bkgTex: 'T_New_XXX_${texNum.toString().padLeft(3, '0')}',
    sku: sku,
    standeeShape: shape,
    texNum: texNum,
  );
}

void main() {
  group('addNrSlot — genre validation', () {
    test('rejects genre not in kNrGenreByte', () {
      final r = addNrSlot(genre: 'Adventure', existing: const []);
      expect(r.isOk, isFalse);
      expect(r.error, AddNrError.unsupportedGenre);
    });

    test('accepts every genre in kNrGenreByte', () {
      for (final g in kNrGenreByte.keys) {
        final r = addNrSlot(
          genre: g,
          existing: const [],
          random: Random(42),
        );
        expect(r.isOk, isTrue, reason: 'genre=$g');
        expect(r.slot!.genre, g);
        expect(r.slot!.genreByte, kNrGenreByte[g]);
        expect(r.slot!.genreCode.length, 3);
      }
    });
  });

  group('addNrSlot — tex_num assignment (Python v1.8.2 reuse-after-delete fix)', () {
    test('Drama (newCount=3) first slot → tex_num=1', () {
      final r = addNrSlot(genre: 'Drama', existing: const [], random: Random(0));
      expect(r.slot!.texNum, 1);
      expect(r.slot!.bkgTex, 'T_New_Dra_001');
    });

    test('Drama: 1,2,3 in use → next is shared (count-mod cycles 1)', () {
      // All base slots used → fall back to (count % slot_count) + 1 = (3 % 3) + 1 = 1
      final existing = [
        _slot(genre: 'Drama', texNum: 1, sku: 50000),
        _slot(genre: 'Drama', texNum: 2, sku: 50001),
        _slot(genre: 'Drama', texNum: 3, sku: 50002),
      ];
      final r = addNrSlot(genre: 'Drama', existing: existing, random: Random(0));
      expect(r.slot!.texNum, 1);
    });

    test('Drama: 1,3 in use → next picks 2 (lowest unused)', () {
      final existing = [
        _slot(genre: 'Drama', texNum: 1, sku: 50000),
        _slot(genre: 'Drama', texNum: 3, sku: 50001),
      ];
      final r = addNrSlot(genre: 'Drama', existing: existing, random: Random(0));
      expect(r.slot!.texNum, 2,
          reason: 'reuse-after-delete fix: lowest unused base slot wins');
    });

    test('Drama: delete-then-add reuses freed tex_num (the v1.8.2 bug fix)', () {
      // Pre-bug: after deleting NR with tex_num=1, adding a new one would
      // pick (count % slot_count) + 1 = (2 % 3) + 1 = 3, colliding with the
      // still-existing tex_num=3. Fixed: pick lowest unused = 1.
      final afterDelete = [
        _slot(genre: 'Drama', texNum: 2, sku: 50001),
        _slot(genre: 'Drama', texNum: 3, sku: 50002),
      ];
      final r = addNrSlot(genre: 'Drama', existing: afterDelete, random: Random(0));
      expect(r.slot!.texNum, 1);
    });

    test('Genre with newCount=0 (Romance) still gets tex_num=1', () {
      // Romance ships no T_New textures but Python still allows the slot —
      // build_newrelease_datatable filters it later. tex_num floor of 1.
      final r = addNrSlot(genre: 'Romance', existing: const [], random: Random(0));
      expect(r.slot!.texNum, 1);
      expect(r.slot!.bkgTex, 'T_New_Rom_001');
    });
  });

  group('addNrSlot — soft cap', () {
    test('rejects when per-genre count is at kNrPerGenreCap', () {
      final existing = [
        for (var i = 0; i < kNrPerGenreCap; i++)
          _slot(genre: 'Drama', texNum: 1, sku: 50000 + i),
      ];
      final r = addNrSlot(genre: 'Drama', existing: existing, random: Random(0));
      expect(r.isOk, isFalse);
      expect(r.error, AddNrError.perGenreCapReached);
    });

    test('cap is per-genre — full Drama does not block a new Horror', () {
      final existing = [
        for (var i = 0; i < kNrPerGenreCap; i++)
          _slot(genre: 'Drama', texNum: 1, sku: 50000 + i),
      ];
      final r = addNrSlot(genre: 'Horror', existing: existing, random: Random(0));
      expect(r.isOk, isTrue);
    });
  });

  group('addNrSlot — SKU generation', () {
    test('SKU is in [kNrSkuMin..kNrSkuMax]', () {
      for (var seed = 0; seed < 20; seed++) {
        final r = addNrSlot(
          genre: 'Drama',
          existing: const [],
          random: Random(seed),
        );
        expect(r.slot!.sku, inInclusiveRange(kNrSkuMin, kNrSkuMax));
      }
    });

    test('SKU avoids collisions with existing slots (cross-genre)', () {
      // Use up almost all SKUs except one — the new slot must land on the
      // single unused id.
      const targetSku = 55555;
      final existing = <NewReleaseSlot>[];
      for (var s = kNrSkuMin; s <= kNrSkuMax; s++) {
        if (s == targetSku) continue;
        existing.add(_slot(genre: 'Horror', texNum: 1, sku: s));
      }
      final r = addNrSlot(
        genre: 'Drama',
        existing: existing,
        random: Random(7),
      );
      expect(r.slot!.sku, targetSku);
    });

    test('returns skuExhausted when range is fully used', () {
      final existing = [
        for (var s = kNrSkuMin; s <= kNrSkuMax; s++)
          _slot(genre: 'Horror', texNum: 1, sku: s),
      ];
      // Horror cap reached too — but skuExhausted is the SKU-side error.
      // Use a different genre that's not full to make sure we hit the
      // SKU branch, not the per-genre branch.
      final r = addNrSlot(
        genre: 'Drama',
        existing: existing,
        random: Random(0),
      );
      expect(r.isOk, isFalse);
      expect(r.error, AddNrError.skuExhausted);
    });
  });

  group('addNrSlot — slot fields', () {
    test('createdAt is set to injected `now`, formatted per nowIso', () {
      // Matches the Python `_now_iso()` format: second-precision, no
      // microseconds, no tz suffix.  See `lib/domain/timestamps.dart`.
      final ts = DateTime.utc(2026, 5, 7, 12, 0, 0);
      final r = addNrSlot(
        genre: 'Drama',
        existing: const [],
        now: ts,
        random: Random(0),
      );
      expect(r.slot!.createdAt, '2026-05-07T12:00:00');
    });

    test('lastEditedAt is null on creation', () {
      final r = addNrSlot(
        genre: 'Drama',
        existing: const [],
        random: Random(0),
      );
      expect(r.slot!.lastEditedAt, isNull);
    });

    test('default title is "New Release", default shape is "A"', () {
      final r = addNrSlot(
        genre: 'Drama',
        existing: const [],
        random: Random(0),
      );
      expect(r.slot!.title, 'New Release');
      expect(r.slot!.standeeShape, 'A');
    });
  });

  group('changeNrSlotGenre', () {
    test('returns null for unsupported genre', () {
      final s = _slot(genre: 'Drama', texNum: 1);
      expect(
        changeNrSlotGenre(slot: s, newGenre: 'Adventure', allSlots: [s]),
        isNull,
      );
    });

    test('updates genre/code/byte/texNum/bkgTex on a normal switch', () {
      final s = _slot(genre: 'Drama', texNum: 1);
      final next = changeNrSlotGenre(
        slot: s,
        newGenre: 'Horror',
        allSlots: [s],
      );
      expect(next, isNotNull);
      expect(next!.genre, 'Horror');
      expect(next.genreCode, 'Hor');
      expect(next.genreByte, kNrGenreByte['Horror']);
      expect(next.texNum, 1);
      expect(next.bkgTex, 'T_New_Hor_001');
      expect(next.sku, s.sku, reason: 'SKU must be preserved');
    });

    test('skips this slot when computing texNum collisions', () {
      // Slot is currently Drama tex=2; switching to Drama again should not
      // wrap because we exclude this slot from the used set.
      final s = _slot(genre: 'Drama', texNum: 2, sku: 50001);
      final other = _slot(genre: 'Drama', texNum: 1, sku: 50002);
      final next = changeNrSlotGenre(
        slot: s,
        newGenre: 'Drama',
        allSlots: [s, other],
      );
      // tex_num=1 is used by other; lowest unused for Drama (newCount=3) is 2.
      expect(next!.texNum, 2);
    });

    test('lowest-unused texNum honours other slots in target genre', () {
      // Slot is Drama; switching to Horror where tex 1, 2 are taken.
      final s = _slot(genre: 'Drama', texNum: 1, sku: 50001);
      final h1 = _slot(genre: 'Horror', texNum: 1, sku: 50002);
      final h2 = _slot(genre: 'Horror', texNum: 2, sku: 50003);
      final next = changeNrSlotGenre(
        slot: s,
        newGenre: 'Horror',
        allSlots: [s, h1, h2],
      );
      expect(next!.texNum, 3);
    });

    test('wraps via count-mod when every base slot in target genre is used',
        () {
      // Horror has newCount=4. Fill 1..4 with other slots, then move our
      // slot to Horror — should wrap to (4 % 4) + 1 = 1.
      final s = _slot(genre: 'Drama', texNum: 1, sku: 50001);
      final fillers = [
        for (var i = 0; i < 4; i++)
          _slot(genre: 'Horror', texNum: i + 1, sku: 50100 + i),
      ];
      final next = changeNrSlotGenre(
        slot: s,
        newGenre: 'Horror',
        allSlots: [s, ...fillers],
      );
      expect(next!.texNum, 1);
    });

    test('keeps texNum/bkgTex when target genre has newCount=0', () {
      // Romance has no T_New textures; Python returns early without
      // touching tex_num/bkg_tex (Z. 9237-9238). We do the same.
      final s = _slot(genre: 'Drama', texNum: 2, sku: 50001);
      final next = changeNrSlotGenre(
        slot: s,
        newGenre: 'Romance',
        allSlots: [s],
      );
      expect(next!.genre, 'Romance');
      expect(next.genreCode, 'Rom');
      expect(next.genreByte, kNrGenreByte['Romance']);
      expect(next.texNum, 2);
      expect(next.bkgTex, s.bkgTex,
          reason: 'no T_New textures → DT builder will drop this slot, '
              'so changing the bkg_tex preview would be misleading');
    });
  });

  group('applyGenreByteAutoFix', () {
    test('returns input unchanged when all bytes match', () {
      final input = [
        _slot(genre: 'Drama', texNum: 1),
        _slot(genre: 'Horror', texNum: 1, sku: 50001),
      ];
      final r = applyGenreByteAutoFix(input);
      expect(r.fixed, 0);
      expect(r.slots[0].genreByte, kNrGenreByte['Drama']);
      expect(r.slots[1].genreByte, kNrGenreByte['Horror']);
    });

    test('fixes a wrong genre_byte and reports the count', () {
      final input = [
        _slot(genre: 'Drama', texNum: 1, genreByte: 0xFF),
        _slot(genre: 'Horror', texNum: 1, sku: 50001), // already correct
        _slot(genre: 'Sci-Fi', texNum: 1, sku: 50002, genreByte: 0xAA),
      ];
      final r = applyGenreByteAutoFix(input);
      expect(r.fixed, 2);
      expect(r.slots[0].genreByte, kNrGenreByte['Drama']);
      expect(r.slots[1].genreByte, kNrGenreByte['Horror']);
      expect(r.slots[2].genreByte, kNrGenreByte['Sci-Fi']);
    });

    test('preserves slots with unknown genres untouched', () {
      // A user-edited file with an obsolete genre name — we don't drop
      // the slot, but we also can't fix what we don't know.
      final input = [
        _slot(genre: 'Drama', texNum: 1).copyWith(
          genre: 'NotAGenre',
        ),
      ];
      final r = applyGenreByteAutoFix(input);
      expect(r.fixed, 0);
      expect(r.slots[0].genre, 'NotAGenre');
    });
  });

  group('NewReleaseSlot JSON round-trip', () {
    test('toJson keeps Python-compatible keys', () {
      final s = _slot(genre: 'Drama', texNum: 2, sku: 51234)
          .copyWith(createdAt: '2026-05-07T12:00:00.000Z');
      final json = s.toJson();
      expect(json['title'], 'NR Drama 2');
      expect(json['genre'], 'Drama');
      expect(json['genre_code'], 'XXX');
      expect(json['genre_byte'], kNrGenreByte['Drama']);
      expect(json['bkg_tex'], 'T_New_XXX_002');
      expect(json['sku'], 51234);
      expect(json['standee_shape'], 'A');
      expect(json['tex_num'], 2);
      expect(json['created_at'], '2026-05-07T12:00:00.000Z');
      expect(json.containsKey('last_edited_at'), isFalse);
    });

    test('fromJson skips malformed entries (returns null)', () {
      expect(NewReleaseSlot.fromJson({'title': 'incomplete'}), isNull);
      expect(
          NewReleaseSlot.fromJson({
            'title': 't',
            'genre': 'Drama',
            // missing fields...
          }),
          isNull);
    });

    test('fromJson accepts minimal valid record', () {
      final s = NewReleaseSlot.fromJson({
        'title': 't',
        'genre': 'Drama',
        'genre_code': 'Dra',
        'genre_byte': 4,
        'bkg_tex': 'T_New_Dra_001',
        'sku': 51000,
        'standee_shape': 'B',
        'tex_num': 1,
      });
      expect(s, isNotNull);
      expect(s!.standeeShape, 'B');
      expect(s.createdAt, isNull);
    });
  });

  // Helper that produces a slot with a real genre code so bkgTex
  // assertions can compare against the canonical 3-digit form.
  NewReleaseSlot mkSlot({
    required String genre,
    required String genreCode,
    required int texNum,
    required int sku,
    String? bkgTex,
  }) {
    return NewReleaseSlot(
      title: '$genre $texNum',
      genre: genre,
      genreCode: genreCode,
      genreByte: kNrGenreByte[genre] ?? 0,
      bkgTex: bkgTex ??
          'T_New_${genreCode}_${texNum.toString().padLeft(3, '0')}',
      sku: sku,
      standeeShape: 'A',
      texNum: texNum,
    );
  }

  group('applyDuplicateTexNumRenumber (legacy modulo bug heal)', () {
    test('returns input unchanged when every (genre, tex_num) is unique', () {
      final input = [
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 1, sku: 50000),
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 2, sku: 50001),
        mkSlot(genre: 'Horror', genreCode: 'Hor', texNum: 1, sku: 50002),
      ];
      final r = applyDuplicateTexNumRenumber(input);
      expect(r.renumbered, 0);
      expect(r.slots, input);
    });

    test('renumbers a same-genre duplicate to the next free slot', () {
      // Drama gets two slots both at tex_num=2 — the second should
      // become tex_num=1 (lowest free in Drama).
      final input = [
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 2, sku: 50000),
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 2, sku: 50001),
      ];
      final r = applyDuplicateTexNumRenumber(input);
      expect(r.renumbered, 1);
      expect(r.slots[0].texNum, 2, reason: 'first occurrence kept');
      expect(r.slots[1].texNum, 1, reason: 'duplicate renumbered to free slot');
      expect(r.slots[1].bkgTex, 'T_New_Dra_001',
          reason: 'renumber rewrites bkgTex to 3-digit form');
      // SKU/title preserved on the renumbered slot.
      expect(r.slots[1].sku, 50001);
    });

    test('renumber is per-genre — same tex_num in different genres is fine',
        () {
      final input = [
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 1, sku: 50000),
        mkSlot(genre: 'Horror', genreCode: 'Hor', texNum: 1, sku: 50001),
      ];
      final r = applyDuplicateTexNumRenumber(input);
      expect(r.renumbered, 0);
      expect(r.slots[0].texNum, 1);
      expect(r.slots[1].texNum, 1);
    });

    test('renumbers a slot with invalid tex_num (<1)', () {
      final input = [
        mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 0, sku: 50000),
      ];
      final r = applyDuplicateTexNumRenumber(input);
      expect(r.renumbered, 1);
      expect(r.slots[0].texNum, 1);
      expect(r.slots[0].bkgTex, 'T_New_Dra_001');
    });

    test('skips bkgTex rewrite when genreCode is empty (defensive)', () {
      // genre_code is required but a malformed JSON might lose it. We
      // still renumber but leave bkgTex alone — caller can re-derive.
      final s = NewReleaseSlot(
        title: 'orphan',
        genre: 'Drama',
        genreCode: '',
        genreByte: 4,
        bkgTex: 'something',
        sku: 50000,
        standeeShape: 'A',
        texNum: 0,
      );
      final r = applyDuplicateTexNumRenumber([s]);
      expect(r.renumbered, 1);
      expect(r.slots[0].texNum, 1);
      expect(r.slots[0].bkgTex, 'something');
    });
  });

  group('applyBkgTex3DigitMigration (v1.8.2 format migration)', () {
    test('rewrites legacy 2-digit bkgTex to 3-digit', () {
      final s = mkSlot(
        genre: 'Drama',
        genreCode: 'Dra',
        texNum: 5,
        sku: 50000,
        bkgTex: 'T_New_Dra_05', // legacy 2-digit
      );
      final r = applyBkgTex3DigitMigration([s]);
      expect(r.migrated, 1);
      expect(r.slots[0].bkgTex, 'T_New_Dra_005');
      expect(r.slots[0].texNum, 5, reason: 'tex_num is preserved verbatim');
    });

    test('returns input unchanged when bkgTex is already 3-digit', () {
      final s = mkSlot(genre: 'Drama', genreCode: 'Dra', texNum: 5, sku: 50000);
      final r = applyBkgTex3DigitMigration([s]);
      expect(r.migrated, 0);
      expect(r.slots[0].bkgTex, 'T_New_Dra_005');
    });

    test('skips slots with empty genreCode', () {
      final s = NewReleaseSlot(
        title: 'orphan',
        genre: 'Drama',
        genreCode: '',
        genreByte: 4,
        bkgTex: 'whatever_2digit_05',
        sku: 50000,
        standeeShape: 'A',
        texNum: 5,
      );
      final r = applyBkgTex3DigitMigration([s]);
      expect(r.migrated, 0);
      expect(r.slots[0].bkgTex, 'whatever_2digit_05');
    });

    test('skips slots with invalid texNum', () {
      final s = mkSlot(
        genre: 'Drama',
        genreCode: 'Dra',
        texNum: 0,
        sku: 50000,
        bkgTex: 'T_New_Dra_garbage',
      );
      final r = applyBkgTex3DigitMigration([s]);
      expect(r.migrated, 0);
      expect(r.slots[0].bkgTex, 'T_New_Dra_garbage');
    });

    test('migrates a mixed batch — only the non-canonical ones change', () {
      final input = [
        mkSlot(
            genre: 'Drama',
            genreCode: 'Dra',
            texNum: 1,
            sku: 50000,
            bkgTex: 'T_New_Dra_01'), // legacy
        mkSlot(genre: 'Horror', genreCode: 'Hor', texNum: 2, sku: 50001),
        // already correct
        mkSlot(
            genre: 'Sci-Fi',
            genreCode: 'Sci',
            texNum: 7,
            sku: 50002,
            bkgTex: 'T_New_Sci_7'), // weird format, also legacy
      ];
      final r = applyBkgTex3DigitMigration(input);
      expect(r.migrated, 2);
      expect(r.slots[0].bkgTex, 'T_New_Dra_001');
      expect(r.slots[1].bkgTex, 'T_New_Hor_002');
      expect(r.slots[2].bkgTex, 'T_New_Sci_007');
    });
  });
}
