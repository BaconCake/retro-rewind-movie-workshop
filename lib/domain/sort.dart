import '../core/constants/genres.dart';
import '../data/datatable/slot_data.dart';
import 'entities/new_release_slot.dart';

/// Sort modes available on each per-tab dropdown.  Six options matching
/// Python's `SORT_OPTIONS` (RR_VHS_Tool.py:2849-2862) — three fields
/// (name / created / edited) × two directions (asc / desc).  The string
/// `key` is what's persisted in `sort_preferences.json` so the file
/// stays portable between the two tools.
enum SortKey {
  nameAsc('name_asc', 'Name', _arrowAsc, _SortField.name, true),
  nameDesc('name_desc', 'Name', _arrowDesc, _SortField.name, false),
  createdAsc('created_asc', 'Created at', _arrowAsc, _SortField.created, true),
  createdDesc(
      'created_desc', 'Created at', _arrowDesc, _SortField.created, false),
  editedAsc('edited_asc', 'Last edited', _arrowAsc, _SortField.edited, true),
  editedDesc(
      'edited_desc', 'Last edited', _arrowDesc, _SortField.edited, false);

  final String wireKey;
  final String label;
  final String arrow;
  final _SortField _field;
  final bool _ascending;

  const SortKey(
      this.wireKey, this.label, this.arrow, this._field, this._ascending);

  /// Parse a wire-format key back to the enum, falling back to [kDefaultSortKey]
  /// for unknown values (forward-compat with future Python sort keys).
  static SortKey fromWireKey(String? key) {
    for (final s in SortKey.values) {
      if (s.wireKey == key) return s;
    }
    return kDefaultSortKey;
  }
}

const String _arrowAsc = '▴'; // ▴
const String _arrowDesc = '▾'; // ▾

enum _SortField { name, created, edited }

/// Default for any tab that has no saved entry — oldest first, matches
/// Python (`DEFAULT_SORT_KEY = "created_asc"`).  Preserves the legacy
/// slot-creation-order behaviour for users with existing libraries.
const SortKey kDefaultSortKey = SortKey.createdAsc;

/// Sort a list of genre-tab slots in place.  Returns a NEW list — the
/// input is never mutated.
///
/// Rules mirror Python's `_sort_textures` (RR_VHS_Tool.py:2895-2947):
///   * Name sort: by `pnName.toLowerCase()`, then by original index
///     (stable for identical titles, insert-order preserved).
///   * Date sort: split into has-timestamp and no-timestamp ranks.
///     Timestamped entries come first (regardless of direction), sorted
///     ISO-8601 (lexicographic == chronological).  No-timestamp entries
///     come last, sorted by original index.  Direction flips order
///     WITHIN each rank but NOT between ranks.
///
/// Genre slots in the current port don't carry timestamps yet (Python's
/// `_mark_edited` is the future-port that writes them), so today every
/// genre slot falls into the no-ts bucket and date sorts are effectively
/// "by slot index" — which is the correct legacy-data fallback shape.
List<SlotData> sortSlots(List<SlotData> slots, SortKey key) {
  final indexed = [
    for (var i = 0; i < slots.length; i++) (i, slots[i]),
  ];
  if (key._field == _SortField.name) {
    indexed.sort((a, b) {
      final c = a.$2.pnName.toLowerCase().compareTo(b.$2.pnName.toLowerCase());
      if (c != 0) return key._ascending ? c : -c;
      return a.$1.compareTo(b.$1); // stable: original index
    });
    return [for (final e in indexed) e.$2];
  }

  // Date sort.  SlotData has no created_at / last_edited_at yet, so
  // _slotTimestamp always returns null today.  Once timestamps are
  // wired, this code just picks them up — no other change needed.
  final withTs = <(int, SlotData, String)>[];
  final noTs = <(int, SlotData)>[];
  for (final (i, s) in indexed) {
    final ts = _slotTimestamp(s, key._field);
    if (ts == null) {
      noTs.add((i, s));
    } else {
      withTs.add((i, s, ts));
    }
  }
  withTs.sort((a, b) {
    final c = a.$3.compareTo(b.$3);
    if (c != 0) return key._ascending ? c : -c;
    return a.$1.compareTo(b.$1);
  });
  noTs.sort((a, b) => key._ascending
      ? a.$1.compareTo(b.$1)
      : b.$1.compareTo(a.$1));
  return [
    for (final e in withTs) e.$2,
    for (final e in noTs) e.$2,
  ];
}

String? _slotTimestamp(SlotData s, _SortField field) {
  // Hook for when SlotData gains created_at / last_edited_at.  Returns
  // null today — every genre slot is treated as legacy / no-timestamp.
  return null;
}

/// Sort an NR slot list, preserving each slot's original position in
/// `nrSlots` as the stable fallback handle.
///
/// Rules mirror Python's `_sort_nr_slots` (RR_VHS_Tool.py:2950-3000):
///   * Name sort: title, then genre-position-in-`kGenres`, then tex_num.
///     Genre rank ties give stable order without leaking insertion order
///     across genre changes.
///   * Date sort: has-ts before no-ts as usual; no-ts entries sort by
///     (genre_pos, tex_num) so legacy NRs cluster by genre tab order.
///     Direction flips order within each rank.
List<NewReleaseSlot> sortNrSlots(List<NewReleaseSlot> nrSlots, SortKey key) {
  // Genre rank uses the canonical kGenres order (the same order the tab
  // bar uses) so the no-ts fallback follows the visible tab layout.
  final genreRank = <String, int>{};
  for (var i = 0; i < kGenres.length; i++) {
    genreRank[kGenres[i].name] = i;
  }
  int pos(NewReleaseSlot n) => genreRank[n.genre] ?? 999;
  int tex(NewReleaseSlot n) => n.texNum;

  final list = [...nrSlots];

  if (key._field == _SortField.name) {
    list.sort((a, b) {
      final c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (c != 0) return key._ascending ? c : -c;
      final p = pos(a).compareTo(pos(b));
      if (p != 0) return key._ascending ? p : -p;
      final t = tex(a).compareTo(tex(b));
      return key._ascending ? t : -t;
    });
    return list;
  }

  final tsField = key._field == _SortField.created ? 'created' : 'edited';
  final withTs = <(NewReleaseSlot, String)>[];
  final noTs = <NewReleaseSlot>[];
  for (final n in list) {
    final ts = tsField == 'created' ? n.createdAt : n.lastEditedAt;
    if (ts == null || ts.isEmpty) {
      noTs.add(n);
    } else {
      withTs.add((n, ts));
    }
  }
  withTs.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    if (c != 0) return key._ascending ? c : -c;
    final p = pos(a.$1).compareTo(pos(b.$1));
    if (p != 0) return key._ascending ? p : -p;
    return tex(a.$1).compareTo(tex(b.$1));
  });
  noTs.sort((a, b) {
    final p = pos(a).compareTo(pos(b));
    if (p != 0) return key._ascending ? p : -p;
    final t = tex(a).compareTo(tex(b));
    return key._ascending ? t : -t;
  });
  return [
    for (final e in withTs) e.$1,
    ...noTs,
  ];
}
