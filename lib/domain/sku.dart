/// Port of RR_VHS_Tool.py's SKU module (lines 1697-1920).
///
/// In the in-game economy, every movie has a SKU integer that encodes:
///   * genre (digit 1)        — see [kGenreSkuPrefix]
///   * star rating (last 2)   — see [kStarOptions]
///   * rarity (LCG bit-trick) — see [skuIsHolo] / [skuIsOld]
///
/// The mapping was reverse-engineered against 34/34 base-game SKUs (Python
/// source comment, March 2026), and the Old/Limited thresholds were
/// cross-checked against 36 in-game samples (April 2026). The Dart port
/// matches the Python implementation byte-for-byte — including the LCG
/// bit-pattern reinterpretation that produces a uniform [0, 1) float from
/// a 32-bit seed.
library;

import 'dart:math';
import 'dart:typed_data';

/// One entry in the "Star Rating" dropdown. `last2` is what gets baked into
/// the SKU's last two digits; `label` is the human-readable string shown
/// in the UI. Order matches RR_VHS_Tool.py:1716-1727.
class StarOption {
  final String label;
  final int last2;

  const StarOption({required this.label, required this.last2});
}

const List<StarOption> kStarOptions = [
  StarOption(label: '5.0 ★  (★★★★★)',     last2: 0),
  StarOption(label: '4.5 ★  Good Critic', last2: 93),
  StarOption(label: '4.0 ★  Good Critic', last2: 83),
  StarOption(label: '3.5 ★  No tag',      last2: 53),
  StarOption(label: '2.5 ★  No tag',      last2: 33),
  StarOption(label: '2.0 ★  No tag',      last2: 23),
  StarOption(label: '1.5 ★  Bad Critic',  last2: 22),
  StarOption(label: '1.0 ★  Bad Critic',  last2: 12),
  StarOption(label: '0.5 ★  Bad Critic',  last2: 3),
  StarOption(label: '0.0 ★  Bad Critic',  last2: 2),
];

/// One entry in the "Rarity" dropdown. Mirrors `RARITY_OPTIONS` —
/// RR_VHS_Tool.py:1730-1735.
class Rarity {
  final String label;
  const Rarity._(this.label);

  static const common = Rarity._('Common');
  static const commonOld = Rarity._('Common (Old)');
  static const limited = Rarity._('Limited Edition (holo)');
  static const random = Rarity._('Random');

  static const List<Rarity> all = [common, commonOld, limited, random];

  static Rarity? byLabel(String label) {
    for (final r in all) {
      if (r.label == label) return r;
    }
    return null;
  }

  @override
  String toString() => label;
}

/// Genre → SKU prefix (the first digit of the resulting SKU).
/// Note: `Kid` and `Kids` both map to 7 — `Kid` is the DataTable name and
/// `Kids` is the UI label, both target the same prefix
/// (RR_VHS_Tool.py:248-249).
const Map<String, int> kGenreSkuPrefix = {
  'Horror':    5,
  'Drama':     4,
  'Sci-Fi':    6,
  'Action':    3,
  'Comedy':    2,
  'Adult':     69,
  'Kid':       7,
  'Kids':      7,
  'Police':    8,
  'Romance':   9,
  'Fantasy':   10,
  'Western':   11,
  'Xmas':      12,
  'Adventure': 13,
};

/// LCG-derived float in `[0.0, 1.0)`. Matches Python's bit-trick:
/// take the 32-bit LCG output, drop 9 LSBs to get a 23-bit mantissa,
/// OR with the float 1.0 exponent (`0x3F800000`), reinterpret as f32,
/// subtract 1.0. Same byte order on read and write — endianness cancels.
double _lcgFloat(int sku) {
  final seed = (sku * 196314165 + 907633515) & 0xFFFFFFFF;
  final fBits = (seed >> 9) | 0x3F800000;
  final bd = ByteData(4)..setUint32(0, fBits, Endian.little);
  return bd.getFloat32(0, Endian.little) - 1.0;
}

/// Limited Edition (holographic) tag — ~2% of SKUs hit this threshold.
bool skuIsHolo(int sku) => _lcgFloat(sku) < 0.019;

/// "Old" tag — cheaper for NPCs to rent. ~20% of SKUs. Holo always
/// implies Old (the threshold is wider). Confirmed Python:1773-1786.
bool skuIsOld(int sku) => _lcgFloat(sku) < 0.20;

/// Decoded star rating + critic tag + holo flag for a SKU.
class SkuInfo {
  final double stars;
  final String critic; // "Good Critic", "Bad Critic", or ""
  final bool isHolo;

  const SkuInfo({
    required this.stars,
    required this.critic,
    required this.isHolo,
  });
}

/// Decode a SKU back to its star rating + critic tag.
/// Bucketing is exactly the if/elif chain from RR_VHS_Tool.py:1869-1880.
SkuInfo skuToInfo(int sku) {
  final last2 = sku % 100;
  final holo = skuIsHolo(sku);
  if (last2 == 0)  return SkuInfo(stars: 5.0, critic: 'Good Critic', isHolo: holo);
  if (last2 >= 90) return SkuInfo(stars: 4.5, critic: 'Good Critic', isHolo: holo);
  if (last2 >= 70) return SkuInfo(stars: 4.0, critic: 'Good Critic', isHolo: holo);
  if (last2 >= 40) return SkuInfo(stars: 3.5, critic: '',            isHolo: holo);
  if (last2 >= 30) return SkuInfo(stars: 2.5, critic: '',            isHolo: holo);
  if (last2 >= 23) return SkuInfo(stars: 2.0, critic: '',            isHolo: holo);
  if (last2 >= 20) return SkuInfo(stars: 1.5, critic: 'Bad Critic',  isHolo: holo);
  if (last2 >= 13) return SkuInfo(stars: 1.5, critic: 'Bad Critic',  isHolo: holo);
  if (last2 >= 10) return SkuInfo(stars: 1.0, critic: 'Bad Critic',  isHolo: holo);
  if (last2 >= 3)  return SkuInfo(stars: 0.5, critic: 'Bad Critic',  isHolo: holo);
  return SkuInfo(stars: 0.0, critic: 'Bad Critic', isHolo: holo);
}

Rarity skuToRarity(int sku) {
  if (skuIsHolo(sku)) return Rarity.limited;
  if (skuIsOld(sku))  return Rarity.commonOld;
  return Rarity.common;
}

/// Compact summary string used by the slot-options preview line.
/// Mirrors `sku_display()` — RR_VHS_Tool.py:1904-1915.
String skuDisplay(int sku) {
  final info = skuToInfo(sku);
  final String rarityStr;
  if (info.isHolo) {
    rarityStr = 'Limited ✦';
  } else if (skuIsOld(sku)) {
    rarityStr = 'Old';
  } else {
    rarityStr = 'Common';
  }
  final criticPart = info.critic.isEmpty ? '' : '  ${info.critic}';
  return '${info.stars.toStringAsFixed(1)}★$criticPart  ·  $rarityStr';
}

/// Generate a SKU that satisfies the given star rating and rarity, picking
/// the first candidate that's not already in [usedSkus].
///
/// Scans 500 candidates in the genre's exact prefix band only — do NOT
/// re-introduce the old ±2 prefix scan (caused cross-genre collisions,
/// see Python:1822-1827).
///
/// `slotIndex` is 1-based, matching the Python caller convention
/// (`(slot_idx + 1)`). For [Rarity.random] a uniform pick from the union
/// of match + other candidates is returned; pass [random] to make the
/// pick deterministic in tests.
int generateSku({
  required String genre,
  required int slotIndex,
  int last2 = 93,
  Rarity rarity = Rarity.common,
  Set<int> usedSkus = const {},
  Random? random,
}) {
  final prefixBase = kGenreSkuPrefix[genre] ?? 5;
  final candidatesMatch = <int>[];
  final candidatesOther = <int>[];

  for (var step = 0; step < 50000; step += 100) {
    final sku = prefixBase * 10000000 + slotIndex * 10000 + step + last2;
    if (usedSkus.contains(sku)) continue;

    final isHolo = skuIsHolo(sku);
    final isOld = skuIsOld(sku);
    final bool ok;
    if (rarity == Rarity.common) {
      ok = !isHolo && !isOld;
    } else if (rarity == Rarity.commonOld) {
      ok = !isHolo && isOld;
    } else if (rarity == Rarity.limited) {
      ok = isHolo; // holo always implies old; no extra check needed
    } else {
      ok = true;
    }

    if (ok) {
      candidatesMatch.add(sku);
    } else {
      candidatesOther.add(sku);
    }
  }

  if (rarity == Rarity.random) {
    final pool = [...candidatesMatch, ...candidatesOther];
    if (pool.isEmpty) {
      return prefixBase * 10000000 + slotIndex * 10000 + last2;
    }
    final r = random ?? Random();
    return pool[r.nextInt(pool.length)];
  }
  if (candidatesMatch.isNotEmpty) return candidatesMatch.first;
  if (candidatesOther.isNotEmpty) return candidatesOther.first;
  return prefixBase * 10000000 + slotIndex * 10000 + last2;
}
