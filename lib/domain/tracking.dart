import 'entities/new_release_slot.dart';
import '../data/datatable/slot_data.dart';

/// Stable identifier for a slot used by the edited/shipped tracking sets.
///
/// Two key shapes, matching Python's `_edited_slots` / `_shipped_slots`
/// conventions (RR_VHS_Tool.py:7726-7787, 14879-14888):
///
///   * Genre slot: the `bkgTex` string (e.g. `T_Bkg_Dra_005`). Stable
///     because a custom genre slot's bkgTex is its identity — the user
///     can't change it without deleting the slot.
///   * NR slot: `"NR_<sku>"` (e.g. `NR_58004`). Stable across genre
///     changes — when the user reroutes a NR Drama → Horror the bkgTex
///     flips but the SKU stays put, so the slot keeps its edited /
///     shipped state.
///
/// Returning the same shape as Python's wire format means edited_slots.json
/// and shipped_slots.json are portable between the two tools without a
/// migration step.
String genreSlotKey(SlotData slot) => slot.bkgTex;
String nrSlotKey(NewReleaseSlot nr) => 'NR_${nr.sku}';

/// Compute the union of all currently-valid tracking keys from the
/// loaded slot lists. Used by [pruneOrphans] on startup to drop stale
/// entries that no longer match any real slot. Pure function — no IO.
///
/// [genreSlotsByGenre] is the same shape `customSlotsProvider` returns:
/// genre name → ordered slot list. NRs is the `nrSlotsProvider` list.
Set<String> validTrackingKeys({
  required Map<String, List<SlotData>> genreSlotsByGenre,
  required List<NewReleaseSlot> nrs,
}) {
  final out = <String>{};
  for (final slots in genreSlotsByGenre.values) {
    for (final s in slots) {
      out.add(genreSlotKey(s));
    }
  }
  for (final nr in nrs) {
    out.add(nrSlotKey(nr));
  }
  return out;
}

/// Drop keys from [tracked] that aren't in [valid]. Returns the pruned
/// set plus the keys that were dropped (callers log these for healing
/// visibility — Python prints a "[Heal] Pruned N orphan…" line).
({Set<String> pruned, Set<String> dropped}) pruneOrphans(
  Set<String> tracked,
  Set<String> valid,
) {
  final dropped = <String>{};
  for (final k in tracked) {
    if (!valid.contains(k)) dropped.add(k);
  }
  if (dropped.isEmpty) {
    return (pruned: tracked, dropped: dropped);
  }
  final pruned = <String>{...tracked}..removeAll(dropped);
  return (pruned: pruned, dropped: dropped);
}
