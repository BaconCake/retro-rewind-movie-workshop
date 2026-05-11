import 'entities/texture_replacement.dart';

/// Result of [applyReplacementsKeyMigration]: the rewritten map plus the
/// number of keys that were renamed.  Callers persist the map only when
/// `migrated > 0` (saves an unnecessary disk write on every launch once
/// users are on the new format).
class ReplacementsKeyMigrationResult {
  final Map<String, TextureReplacement> entries;
  final int migrated;
  const ReplacementsKeyMigrationResult({
    required this.entries,
    required this.migrated,
  });
}

/// Migrate legacy 2-digit `T_Bkg_<code>_NN` and `T_New_<code>_NN` keys
/// in `replacements.json` to the v1.8.2 3-digit format
/// (`T_Bkg_<code>_NNN` / `T_New_<code>_NNN`).
///
/// Mirrors Python's `_remap_slot_to_3digit` loop in `load_replacements`
/// (RR_VHS_Tool.py:3022-3038).  Closes the gap left by slice 2a.5: that
/// slice migrated `nr_custom_slots.json` bkg_tex values to 3-digit but
/// not the matching keys in `replacements.json`, so existing NR covers
/// orphaned at launch — the slot's bkgTex was `T_New_Dra_001` but the
/// replacement was still keyed `T_New_Dra_01`.
///
/// **Divergence from Python**: Python's `migrate_nr_replacements` deletes
/// all `T_New_*` keys on the assumption that NR replacements are keyed
/// by `NR_<sku>`.  The Flutter port keys NR replacements by `bkgTex`
/// (`T_New_<code>_NNN`) — same scheme as genre slots — so we **rename**
/// rather than delete, preserving the user's images across the upgrade.
///
/// Conflict policy: if both `T_New_Hor_03` (legacy) and `T_New_Hor_003`
/// (new) exist, iteration order wins (later write replaces earlier).
/// In practice legacy entries were written first, so the new 3-digit
/// entry takes precedence — matches Python's dict-order behaviour.
ReplacementsKeyMigrationResult applyReplacementsKeyMigration(
  Map<String, TextureReplacement> entries,
) {
  var migrated = 0;
  final out = <String, TextureReplacement>{};
  for (final entry in entries.entries) {
    final newKey = _remapSlotKey(entry.key);
    if (newKey != entry.key) migrated++;
    out[newKey] = entry.value;
  }
  return ReplacementsKeyMigrationResult(entries: out, migrated: migrated);
}

/// Rewrite a single key to the 3-digit form when it matches the legacy
/// 2-digit pattern.  Returns the input unchanged for keys we don't
/// recognise (custom keys, already-3-digit, malformed).
String _remapSlotKey(String key) {
  if (!key.startsWith('T_Bkg_') && !key.startsWith('T_New_')) return key;
  final parts = key.split('_');
  if (parts.length < 4) return key;
  final numPart = parts[3];
  if (numPart.length >= 3) return key; // already 3-digit (or longer)
  final n = int.tryParse(numPart);
  if (n == null) return key;
  parts[3] = n.toString().padLeft(3, '0');
  return parts.join('_');
}
