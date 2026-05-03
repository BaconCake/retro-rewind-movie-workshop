import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/domain/sku.dart';

/// Coverage gap fenced in: the Python tool reverse-engineered SKU encoding
/// from in-game data (34/34 confirmed for stars, 36 confirmed for Old/holo)
/// but never tested its own implementation. Port + tests pin both.
void main() {
  group('starsToLast2', () {
    test('every valid half-star maps to its STAR_OPTIONS last2', () {
      // (stars, expected last2) pairs — list of records avoids the
      // "double-key in const map" lint.
      final cases = <(double, int)>[
        (5.0, 0),
        (4.5, 93),
        (4.0, 83),
        (3.5, 53),
        (2.5, 33),
        (2.0, 23),
        (1.5, 22),
        (1.0, 12),
        (0.5, 3),
        (0.0, 2),
      ];
      for (final (stars, last2) in cases) {
        expect(starsToLast2(stars), last2, reason: 'stars=$stars');
      }
    });

    test('3.0 snaps to 2.5 (Python explicitly rejects 3.0)', () {
      expect(starsToLast2(3.0), 33);
    });

    test('falls back to 53 (3.5★) for off-grid input', () {
      expect(starsToLast2(2.7), 53);
      expect(starsToLast2(99.0), 53);
    });
  });

  group('skuToInfo', () {
    test('every STAR_OPTIONS last2 round-trips to its star rating', () {
      // Each StarOption.last2 should decode back to the leading number in
      // its own label — that's the round-trip guarantee the dropdown leans
      // on (pick "4.5 ★", get a SKU, decode it, see "4.5 ★").
      const expected = {
        0: 5.0,
        93: 4.5,
        83: 4.0,
        53: 3.5,
        33: 2.5,
        23: 2.0,
        22: 1.5,
        12: 1.0,
        3: 0.5,
        2: 0.0,
      };
      for (final opt in kStarOptions) {
        final stars = skuToInfo(50000000 + opt.last2).stars;
        expect(stars, expected[opt.last2],
            reason: 'last2=${opt.last2} (${opt.label})');
      }
    });

    test('confirmed base-game Horror SKU "The Sixth Sense" decodes to 4.0★',
        () {
      // RR_VHS_Tool.py:4226 — `{"sku":5304473, "pn_name":"The Sixth Sense"}`.
      // last2 = 73 → bucket "if last2 >= 70: 4.0 / Good Critic".
      final info = skuToInfo(5304473);
      expect(info.stars, 4.0);
      expect(info.critic, 'Good Critic');
    });

    test('confirmed base-game "Pulp Fiction" decodes to 4.5★', () {
      // Python:4258 — sku 1532392, last2 = 92 → bucket >= 90 → 4.5
      final info = skuToInfo(1532392);
      expect(info.stars, 4.5);
      expect(info.critic, 'Good Critic');
    });

    test('boundary: last2 = 89 → 4.0 (not yet 4.5)', () {
      expect(skuToInfo(50000089).stars, 4.0);
    });

    test('boundary: last2 = 90 → 4.5', () {
      expect(skuToInfo(50000090).stars, 4.5);
    });

    test('special case: last2 == 0 → 5.0 (the perfect-score branch)', () {
      expect(skuToInfo(50000000).stars, 5.0);
    });
  });

  group('skuIsHolo / skuIsOld', () {
    test('holo always implies old (threshold 0.019 < 0.20)', () {
      // Walk a sweep of SKUs; whenever holo is true, old must also be true.
      var checked = 0;
      var holos = 0;
      for (var i = 0; i < 5000; i++) {
        final sku = 50000000 + i * 7;
        if (skuIsHolo(sku)) {
          holos++;
          expect(skuIsOld(sku), isTrue,
              reason: 'sku=$sku is holo but not old');
        }
        checked++;
      }
      // Sanity: we should hit *some* holos in 5000 samples (~2% expected).
      expect(holos, greaterThan(0), reason: 'no holo SKUs in $checked samples');
    });

    test('determinism: same SKU → same flag', () {
      const sku = 5_555_555;
      expect(skuIsHolo(sku), skuIsHolo(sku));
      expect(skuIsOld(sku), skuIsOld(sku));
    });

    test('overall holo/old rate matches Python\'s ~2% / ~20% targets', () {
      // Loose sanity bounds — tighten if drift becomes an issue.
      var holo = 0;
      var old = 0;
      const n = 10000;
      for (var i = 0; i < n; i++) {
        final sku = 1_000_000 + i;
        if (skuIsHolo(sku)) holo++;
        if (skuIsOld(sku)) old++;
      }
      expect(holo / n, inInclusiveRange(0.005, 0.04));
      expect(old / n, inInclusiveRange(0.15, 0.25));
    });
  });

  group('skuToRarity', () {
    test('classification matches the holo/old flags', () {
      for (var i = 0; i < 500; i++) {
        final sku = 5_000_000 + i * 13;
        final rarity = skuToRarity(sku);
        if (skuIsHolo(sku)) {
          expect(rarity, Rarity.limited, reason: 'sku=$sku');
        } else if (skuIsOld(sku)) {
          expect(rarity, Rarity.commonOld, reason: 'sku=$sku');
        } else {
          expect(rarity, Rarity.common, reason: 'sku=$sku');
        }
      }
    });
  });

  group('skuDisplay', () {
    test('formats stars with one decimal, includes critic + rarity', () {
      // Pick a base-game SKU to keep the assertion concrete.
      // "The Sixth Sense" → 4.0★ Good Critic, classifier depends on LCG.
      final s = skuDisplay(5304473);
      expect(s, startsWith('4.0★'));
      expect(s, contains('Good Critic'));
      expect(s, contains('·'));
    });

    test('omits the critic chunk when no tag', () {
      // last2=53 falls in the "" critic bucket (3.5★ no tag).
      final s = skuDisplay(50000053);
      expect(s, startsWith('3.5★'));
      expect(s.contains('Critic'), isFalse);
    });
  });

  group('generateSku', () {
    test('uses the genre prefix as the leading digit(s)', () {
      // Adult is the only 2-digit prefix (69) — good edge case.
      final adultSku = generateSku(genre: 'Adult', slotIndex: 1);
      expect(adultSku ~/ 10_000_000, 69);
      final horrorSku = generateSku(genre: 'Horror', slotIndex: 1);
      expect(horrorSku ~/ 10_000_000, 5);
    });

    test('result is deterministic for non-Random rarity', () {
      final a = generateSku(
        genre: 'Drama',
        slotIndex: 7,
        last2: 53,
      );
      final b = generateSku(
        genre: 'Drama',
        slotIndex: 7,
        last2: 53,
      );
      expect(a, b);
    });

    test('result\'s last2 == requested last2 (round-trip)', () {
      for (final opt in kStarOptions) {
        final sku = generateSku(
          genre: 'Horror',
          slotIndex: 5,
          last2: opt.last2,
        );
        expect(sku % 100, opt.last2,
            reason: 'requested ${opt.last2}, got ${sku % 100}');
      }
    });

    test('result respects the requested rarity (Common excludes holo + old)',
        () {
      for (var idx = 1; idx <= 10; idx++) {
        for (final opt in kStarOptions) {
          final sku = generateSku(
            genre: 'Horror',
            slotIndex: idx,
            last2: opt.last2,
          );
          expect(skuIsHolo(sku), isFalse,
              reason: 'Common SKU $sku is holo (idx=$idx, last2=${opt.last2})');
          expect(skuIsOld(sku), isFalse,
              reason: 'Common SKU $sku is old (idx=$idx, last2=${opt.last2})');
        }
      }
    });

    test('result respects rarity = Limited (holo)', () {
      // Limited (holo) is the rarest constraint (~2%) — confirm we can hit
      // it across genres without falling through to the unmatched fallback.
      for (final genre in ['Horror', 'Drama', 'Adult', 'Action']) {
        final sku = generateSku(
          genre: genre,
          slotIndex: 3,
          last2: 93,
          rarity: Rarity.limited,
        );
        expect(skuIsHolo(sku), isTrue, reason: 'genre=$genre');
      }
    });

    test('result respects rarity = Common (Old)', () {
      final sku = generateSku(
        genre: 'Drama',
        slotIndex: 4,
        last2: 53,
        rarity: Rarity.commonOld,
      );
      expect(skuIsHolo(sku), isFalse);
      expect(skuIsOld(sku), isTrue);
    });

    test('skips usedSkus and returns the next free candidate', () {
      // Generate once to learn what would normally be returned, then add
      // it to usedSkus and confirm we get a different (later) candidate.
      final first = generateSku(
        genre: 'Drama',
        slotIndex: 4,
        last2: 53,
      );
      final second = generateSku(
        genre: 'Drama',
        slotIndex: 4,
        last2: 53,
        usedSkus: {first},
      );
      expect(second, isNot(first));
      expect(second % 100, 53);
    });

    test('Random rarity returns a value in the allowed pool', () {
      // Seed the Random so the test is deterministic.
      final r = Random(42);
      final sku = generateSku(
        genre: 'Drama',
        slotIndex: 1,
        last2: 53,
        rarity: Rarity.random,
        random: r,
      );
      expect(sku % 100, 53);
      expect(sku ~/ 10_000_000, 4); // Drama prefix
    });
  });
}
