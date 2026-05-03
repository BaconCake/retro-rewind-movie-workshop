/// Naming + index allocation for custom slots — pure functions, no I/O.
/// Mirrors RR_VHS_Tool.py's `add_movie_slot` (lines 4555-4633) and
/// `get_custom_slot_si` (line 1683-1695).
library;

/// First base-game-free `T_Sub_NN` index used by custom slots.
/// Below this is base game (T_Sub_01..T_Sub_77).
const int kTSubCustomBase = 78;

/// Highest `T_Sub_NN` we use for custom slots before wrapping back to
/// [kTSubCustomBase]. The cap exists because the T_Sub uasset clone
/// template hardcodes an 8-character name (`T_Sub_XX`); 3-digit names
/// would break the binary patch (RR_VHS_Tool.py:1683-1695).
const int kTSubCustomMax = 99;

/// Per-genre maximum custom slot index. RR_VHS_Tool.py:1937-1949 sets
/// `bkg_max=999` for every genre.
const int kBkgMax = 999;

/// Genres the Add Slot dialog hides — Adventure parses but isn't used
/// in-game (RR_VHS_Tool.py:1923).  Visible in the shelf if existing
/// slots reference it, but new adds aren't allowed here.
const Set<String> kHiddenGenres = {'Adventure'};

/// Format a custom-slot bkg_tex name. Matches Python:
///   * 1..99   → 3-digit zero-padded ("T_Bkg_Dra_001")
///   * 100+    → no padding ("T_Bkg_Dra_100")
String formatCustomBkgTex(String code, int idx) {
  if (idx < 100) {
    return 'T_Bkg_${code}_${idx.toString().padLeft(3, '0')}';
  }
  return 'T_Bkg_${code}_$idx';
}

/// Pick the lowest unused custom slot index ≥ 1 in [genreSlotBkgTexes].
/// Considers only well-formed `T_Bkg_<code>_<digits>` names; malformed
/// entries are ignored (matches Python's try/except ValueError at
/// RR_VHS_Tool.py:4587-4590).
int nextFreeSlotIndex(String code, Iterable<String> existingBkgTexes) {
  final prefix = 'T_Bkg_${code}_';
  final used = <int>{};
  for (final name in existingBkgTexes) {
    if (!name.startsWith(prefix)) continue;
    final tail = name.substring(prefix.length);
    final n = int.tryParse(tail);
    if (n != null) used.add(n);
  }
  var idx = 1;
  while (used.contains(idx)) {
    idx++;
  }
  return idx;
}

/// Subject texture for the [oneBased]-th custom slot in a genre's list.
/// Wraps after T_Sub_99 → T_Sub_78 (Python:1693).  All custom T_Sub
/// uassets are written as identical transparent 512×512 DXT1 in the
/// pak builder, so sharing names across slots is safe.
String customSlotSubTex(int oneBased) {
  const range = kTSubCustomMax - kTSubCustomBase + 1; // 22 distinct names
  final n = kTSubCustomBase + ((oneBased - 1) % range);
  return 'T_Sub_${n.toString().padLeft(2, '0')}';
}
