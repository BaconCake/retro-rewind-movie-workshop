/// Pure logic for adding/removing New Release slots — no I/O.
/// Mirrors RR_VHS_Tool.py's `add_nr_slot` (Z. 2070-2145) and
/// `remove_nr_slot` (Z. 2147-2154).
library;

import 'dart:math';

import '../core/constants/genres.dart';
import '../core/constants/new_release.dart';
import 'entities/new_release_slot.dart';

/// Result of [addNrSlot]: either the newly-created slot, or a reason it
/// couldn't be added.  We return a tagged result instead of returning null
/// so the UI can surface the right error message.
class AddNrResult {
  final NewReleaseSlot? slot;
  final AddNrError? error;

  const AddNrResult.ok(this.slot) : error = null;
  const AddNrResult.err(this.error) : slot = null;

  bool get isOk => slot != null;
}

enum AddNrError {
  /// Genre has no base game T_New textures (not in [kNrGenreByte]).
  unsupportedGenre,

  /// Already at [kNrPerGenreCap] for this genre.
  perGenreCapReached,

  /// Couldn't find an unused 5-digit SKU in [kNrSkuMin]..[kNrSkuMax]
  /// — only happens if 10000 NRs already exist, which the per-genre cap
  /// makes impossible in practice, but the contract is here for safety.
  skuExhausted,
}

/// Append a new NR slot for [genre] to [existing] and return the new
/// slot wrapped in an [AddNrResult].  Pure — caller decides whether to
/// persist.  [now] and [random] are injected so tests can pin them.
///
/// Behavior matches Python `add_nr_slot` (Z. 2070-2145):
///   * Reject genres not in [kNrGenreByte].
///   * Reject when this genre is already at [kNrPerGenreCap].
///   * Pick the **lowest unused** tex_num in 1..base_new_count for the
///     genre.  Only when all base slots are in use, fall back to
///     `(count % slot_count) + 1` to share a texture (Python's
///     bug-fixed v1.8.2 behavior — the previous formula assigned
///     already-used tex_nums after a deletion).
///   * SKU = uniform random in [kNrSkuMin]..[kNrSkuMax], retried until
///     unused across all NR slots (cross-genre uniqueness).
AddNrResult addNrSlot({
  required String genre,
  required List<NewReleaseSlot> existing,
  String title = 'New Release',
  String standeeShape = 'A',
  DateTime? now,
  Random? random,
}) {
  final genreByte = kNrGenreByte[genre];
  if (genreByte == null) return const AddNrResult.err(AddNrError.unsupportedGenre);

  final perGenreCount = existing.where((s) => s.genre == genre).length;
  if (perGenreCount >= kNrPerGenreCap) {
    return const AddNrResult.err(AddNrError.perGenreCapReached);
  }

  final genreInfo = kGenres.firstWhere((g) => g.name == genre);
  final code = genreInfo.code;
  final slotCount = max(genreInfo.newCount, 1);

  // Lowest unused base slot first; fall back to count-mod-share.
  final usedTexNums = {
    for (final s in existing.where((s) => s.genre == genre)) s.texNum,
  };
  int? texNum;
  for (var n = 1; n <= slotCount; n++) {
    if (!usedTexNums.contains(n)) {
      texNum = n;
      break;
    }
  }
  texNum ??= (perGenreCount % slotCount) + 1;

  final bkgTex = 'T_New_${code}_${texNum.toString().padLeft(2, '0')}';

  // SKU: uniform-random unused id in [kNrSkuMin..kNrSkuMax].
  final usedSkus = {for (final s in existing) s.sku};
  final rng = random ?? Random();
  final skuRange = kNrSkuMax - kNrSkuMin + 1;
  if (usedSkus.length >= skuRange) {
    return const AddNrResult.err(AddNrError.skuExhausted);
  }
  int sku;
  do {
    sku = kNrSkuMin + rng.nextInt(skuRange);
  } while (usedSkus.contains(sku));

  final ts = (now ?? DateTime.now().toUtc()).toIso8601String();

  return AddNrResult.ok(NewReleaseSlot(
    title: title,
    genre: genre,
    genreCode: code,
    genreByte: genreByte,
    bkgTex: bkgTex,
    sku: sku,
    standeeShape: standeeShape,
    texNum: texNum,
    createdAt: ts,
  ));
}

/// Apply the genre_byte auto-fix Python performs on load (Z. 2055-2067).
/// Returns the corrected list and the count of slots whose `genreByte`
/// disagreed with [kNrGenreByte].  Caller decides whether to re-persist.
({List<NewReleaseSlot> slots, int fixed}) applyGenreByteAutoFix(
  List<NewReleaseSlot> slots,
) {
  var fixed = 0;
  final out = <NewReleaseSlot>[];
  for (final s in slots) {
    final correct = kNrGenreByte[s.genre];
    if (correct != null && correct != s.genreByte) {
      out.add(s.copyWith(genreByte: correct));
      fixed++;
    } else {
      out.add(s);
    }
  }
  return (slots: out, fixed: fixed);
}

