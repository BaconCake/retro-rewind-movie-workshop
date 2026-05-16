/// Pure logic for adding/removing New Release slots — no I/O.
/// Mirrors RR_VHS_Tool.py's `add_nr_slot` (Z. 2070-2145) and
/// `remove_nr_slot` (Z. 2147-2154).
library;

import 'dart:math';

import '../core/constants/genres.dart';
import '../core/constants/new_release.dart';
import 'entities/new_release_slot.dart';
import 'timestamps.dart';

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
/// Behavior matches Python `add_nr_slot` (RR_VHS_Tool.py:2115-2155):
///   * Reject genres not in [kNrGenreByte].
///   * Reject when this genre is already at [kNrPerGenreCap].
///   * Pick the **lowest unused** tex_num in `1..kNrPerGenreCap` for
///     the genre (Python's `range(1, 1000)`, Z. 2133).  Unlike base
///     game slot picks, this is not bounded by `genreInfo.newCount` —
///     slots beyond the base count get cloned at build time via the
///     T_New_Hor_01 donor (see `writeNrDonorClone`).
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

  // Lowest unused tex_num in 1..kNrPerGenreCap (Python's range(1, 1000),
  // Z. 2133).  The early per-genre cap check above guarantees this loop
  // finds a value — at most kNrPerGenreCap-1 entries are used, so the
  // smallest free integer is always within range.
  final usedTexNums = {
    for (final s in existing.where((s) => s.genre == genre)) s.texNum,
  };
  int? candidate;
  for (var n = 1; n <= kNrPerGenreCap; n++) {
    if (!usedTexNums.contains(n)) {
      candidate = n;
      break;
    }
  }
  final texNum = candidate!;  // Guaranteed by perGenreCount cap check above.

  final bkgTex = 'T_New_${code}_${texNum.toString().padLeft(3, '0')}';

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

  final ts = nowIso(now);

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

/// Re-target [slot] at [newGenre], preserving its SKU but recomputing
/// `genreCode`, `genreByte`, `texNum`, and `bkgTex`.  Pure port of
/// Python's `_on_nr_genre_change` (RR_VHS_Tool.py:9861-9881).
///
/// `texNum` picks the lowest unused tex_num for [newGenre] across
/// [allSlots] **excluding** [slot] itself, in `1..kNrPerGenreCap`
/// (Python's `range(1, 1000)`, Z. 9877).  No base-game cap, no
/// modulo-recycle — slots beyond `newCount` get auto-cloned at build
/// from the T_New_Hor_01 donor (see `writeNrDonorClone`).
///
/// Returns null when [newGenre] isn't in [kNrGenreByte] — caller should
/// reject the change.  For Romance/Western (`newCount == 0`) the slot
/// gets a tex_num/bkg_tex like any other genre (Python sets them
/// unconditionally, Z. 9877-9879); the DT builder filters those rows
/// out at build time.
NewReleaseSlot? changeNrSlotGenre({
  required NewReleaseSlot slot,
  required String newGenre,
  required List<NewReleaseSlot> allSlots,
}) {
  final genreByte = kNrGenreByte[newGenre];
  if (genreByte == null) return null;

  final genreInfo = kGenres.firstWhere((g) => g.name == newGenre);
  final code = genreInfo.code;

  // Lowest unused tex_num in 1..kNrPerGenreCap.  Mirrors addNrSlot.
  // [slot] is excluded from the used set so re-selecting the slot's
  // current genre is idempotent (the slot's own tex_num stays free).
  final usedTexNums = {
    for (final s in allSlots)
      if (s.sku != slot.sku && s.genre == newGenre) s.texNum,
  };
  int? candidate;
  for (var n = 1; n <= kNrPerGenreCap; n++) {
    if (!usedTexNums.contains(n)) {
      candidate = n;
      break;
    }
  }
  // Guaranteed by per-genre cap invariant — even if every NR in the
  // app moved to `newGenre`, at most kNrPerGenreCap-1 of them could
  // share that genre minus this slot.
  final texNum = candidate!;

  final bkgTex = 'T_New_${code}_${texNum.toString().padLeft(3, '0')}';

  return slot.copyWith(
    genre: newGenre,
    genreCode: code,
    genreByte: genreByte,
    texNum: texNum,
    bkgTex: bkgTex,
  );
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

/// Auto-repair for legacy data: when two NRs in the same genre share a
/// `texNum` (the pre-v1.8.2 modulo allocator could pick already-used
/// slot numbers after a deletion), keep the FIRST occurrence and
/// renumber later duplicates to the next free slot in 1..999.  Pure
/// port of the renumber loop in Python's `_load_nr_slots`
/// (RR_VHS_Tool.py:2072-2090).
///
/// Renumbered slots also get their [bkgTex] rewritten to the 3-digit
/// form `T_New_<code>_<NN:03d>`, matching Python.  Slots with an
/// invalid [texNum] (`< 1`) are renumbered too.  Caller decides whether
/// to re-persist (the count > 0 case).
///
/// Operates per-genre — duplicates across genres are unaffected (a
/// `tex_num` collision between Drama and Horror is fine because each
/// genre has its own T_New texture set).
({List<NewReleaseSlot> slots, int renumbered}) applyDuplicateTexNumRenumber(
  List<NewReleaseSlot> slots,
) {
  // genre → set of tex_nums kept so far.
  final seenPerGenre = <String, Set<int>>{};
  var renumbered = 0;
  final out = <NewReleaseSlot>[];
  for (final s in slots) {
    final used = seenPerGenre.putIfAbsent(s.genre, () => <int>{});
    if (s.texNum < 1 || used.contains(s.texNum)) {
      // Pick the next free slot in 1..999 (Python uses range(1, 1000)).
      var newT = 1;
      while (used.contains(newT)) {
        newT++;
        if (newT >= 1000) break;
      }
      // genreCode is the source of truth for the bkgTex prefix; if it's
      // empty (shouldn't happen post-load) we leave bkgTex as-is.
      final newBkgTex = s.genreCode.isEmpty
          ? s.bkgTex
          : 'T_New_${s.genreCode}_${newT.toString().padLeft(3, '0')}';
      out.add(s.copyWith(texNum: newT, bkgTex: newBkgTex));
      used.add(newT);
      renumbered++;
    } else {
      out.add(s);
      used.add(s.texNum);
    }
  }
  return (slots: out, renumbered: renumbered);
}

/// Migrate legacy 2-digit `bkg_tex` values (`T_New_Hor_05`) to the
/// v1.8.2 3-digit format (`T_New_Hor_005`).  Pure port of Python's
/// migration loop (RR_VHS_Tool.py:2091-2107).  3-digit bypasses UE's
/// AssetRegistry bottleneck — UE resolves 3-digit names via pak
/// filename lookup, so custom NR slots beyond the base game count
/// actually load in-game.
///
/// Only changes the [bkgTex] string; [texNum] is preserved verbatim.
/// Slots with an empty [genreCode] or invalid [texNum] are left
/// untouched (defensive — those should be filtered upstream by
/// [applyDuplicateTexNumRenumber]).
({List<NewReleaseSlot> slots, int migrated}) applyBkgTex3DigitMigration(
  List<NewReleaseSlot> slots,
) {
  var migrated = 0;
  final out = <NewReleaseSlot>[];
  for (final s in slots) {
    if (s.genreCode.isEmpty || s.texNum < 1) {
      out.add(s);
      continue;
    }
    final expected =
        'T_New_${s.genreCode}_${s.texNum.toString().padLeft(3, '0')}';
    if (s.bkgTex != expected) {
      out.add(s.copyWith(bkgTex: expected));
      migrated++;
    } else {
      out.add(s);
    }
  }
  return (slots: out, migrated: migrated);
}

