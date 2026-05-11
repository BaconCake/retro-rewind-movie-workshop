import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-tab sort preferences, persisted in `sort_preferences.json` next
/// to the Flutter executable.  Matches Python's `SORT_PREFS_FILE`
/// location (RR_VHS_Tool.py:560) so the file is portable between the
/// two tools.
///
/// File format: top-level JSON object — tab name → wire sort key.  Tab
/// names are either a full genre name (e.g. `"Action"`, `"Horror"`) or
/// the literal `"New Releases"` for the NR tab.  Keys not present
/// default to [kDefaultSortKey] when read by the domain layer (loader
/// returns the raw map verbatim).
class SortPrefsDataSource {
  final String workingDir;
  const SortPrefsDataSource(this.workingDir);

  String get filePath => p.join(workingDir, 'sort_preferences.json');

  /// Load the persisted map.  Returns empty map for missing / blank /
  /// malformed file — every tab then falls back to default at read
  /// time.  Mirrors Python's `load_sort_prefs` (Z. 2764-2774) which
  /// silently swallows exceptions.
  Future<Map<String, String>> load() async {
    final f = File(filePath);
    if (!await f.exists()) return <String, String>{};
    final src = await f.readAsString();
    if (src.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(src);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  /// Persist the map.  Pretty-printed with 2-space indent to match
  /// Python's `json.dump(..., indent=2)` (Z. 2781) — keeps cross-tool
  /// diffs minimal.
  Future<void> save(Map<String, String> prefs) async {
    final encoded = const JsonEncoder.withIndent('  ').convert(prefs);
    await File(filePath).writeAsString(encoded);
  }
}
