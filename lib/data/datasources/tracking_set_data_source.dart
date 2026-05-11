import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Reads / writes a set-of-strings file shared with the Python tool —
/// `edited_slots.json` (RR_VHS_Tool.py:558) or `shipped_slots.json`
/// (Z. 559). Stored on disk as a JSON array of strings.
///
/// File-level behaviour mirrors Python's `load_edited_slots` (Z. 2727):
/// missing or malformed file → empty set. Set semantics are preserved
/// in memory; the on-disk representation is a sorted array (matching
/// Python's `json.dump(sorted(edited), f)` at Z. 2741) so diffs stay
/// stable when both tools touch the file in turn.
class TrackingSetDataSource {
  final String workingDir;
  final String fileName;

  const TrackingSetDataSource({
    required this.workingDir,
    required this.fileName,
  });

  String get filePath => p.join(workingDir, fileName);

  /// Load the set; returns an empty set if the file is missing,
  /// blank, or malformed. Non-string entries are skipped.
  Future<Set<String>> load() async {
    final f = File(filePath);
    if (!await f.exists()) return <String>{};
    final src = await f.readAsString();
    if (src.trim().isEmpty) return <String>{};
    final decoded = jsonDecode(src);
    if (decoded is! List) return <String>{};
    return <String>{
      for (final item in decoded)
        if (item is String) item,
    };
  }

  /// Persist [keys] as a sorted JSON array. Sorted output matches
  /// Python's behaviour and keeps cross-tool diffs minimal.
  Future<void> save(Set<String> keys) async {
    final sorted = keys.toList()..sort();
    await File(filePath).writeAsString(jsonEncode(sorted));
  }

  /// Delete the file from disk. Used by `clearEdited` semantics —
  /// Python's `clear_edited_slots` (Z. 2745) removes the file rather
  /// than writing `[]`, so an empty-on-disk state is byte-identical
  /// between the two tools.
  Future<void> delete() async {
    final f = File(filePath);
    if (await f.exists()) await f.delete();
  }
}
