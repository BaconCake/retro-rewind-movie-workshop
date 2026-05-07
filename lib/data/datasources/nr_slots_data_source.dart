import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/entities/new_release_slot.dart';

/// Reads `nr_custom_slots.json` next to the Flutter executable, matching
/// the Python tool's `NR_SLOTS_FILE` location (RR_VHS_Tool.py:2041) — the
/// same on-disk format so users can switch tools without losing data.
///
/// The file is a JSON array of NR slot objects. Malformed entries are
/// skipped individually, mirroring Python's tolerant behavior.
class NrSlotsDataSource {
  final String workingDir;

  NrSlotsDataSource(this.workingDir);

  String get filePath => p.join(workingDir, 'nr_custom_slots.json');

  /// Returns the persisted NR slot list. Missing or empty file → empty
  /// list. Malformed entries are skipped individually.
  ///
  /// **Note:** the genre_byte auto-fix (Python Z. 2055-2067) is **not**
  /// applied here — that's a domain concern, handled by
  /// `applyGenreByteAutoFix` in `nr_slot_logic.dart`. The data source
  /// returns what's on disk verbatim; the caller decides whether to
  /// re-persist after the fix runs.
  Future<List<NewReleaseSlot>> load() async {
    final f = File(filePath);
    if (!await f.exists()) return const [];
    final src = await f.readAsString();
    if (src.trim().isEmpty) return const [];

    final decoded = jsonDecode(src);
    if (decoded is! List) {
      throw const FormatException(
          'nr_custom_slots.json root must be a JSON array');
    }

    final out = <NewReleaseSlot>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final slot = NewReleaseSlot.fromJson(item);
      if (slot != null) out.add(slot);
    }
    return out;
  }

  /// Persist [slots] to `nr_custom_slots.json`. Pretty-printed with
  /// 2-space indent, matching Python's `json.dump(..., indent=2)` so
  /// diffs stay readable when both tools touch the same file.
  Future<void> save(List<NewReleaseSlot> slots) async {
    final encoded = const JsonEncoder.withIndent('  ')
        .convert([for (final s in slots) s.toJson()]);
    await File(filePath).writeAsString(encoded);
  }
}
