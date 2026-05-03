import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../datatable/slot_data.dart';

/// Reads `custom_slots.json` next to the Flutter executable, matching the
/// Python tool's `CUSTOM_SLOTS_FILE` location (RR_VHS_Tool.py:556).
///
/// File shape (top-level object keyed by DataTable name, values are arrays):
///
/// ```json
/// {
///   "Drama": [
///     {
///       "bkg_tex":  "T_Bkg_Dra_001",
///       "sub_tex":  "T_Sub_78",
///       "pn_name":  "My Custom Movie",
///       "ls":       0,
///       "lsc":      4,
///       "sku":      40200012,
///       "ntu":      false
///     }
///   ]
/// }
/// ```
///
/// Each entry maps to one DataTable row in the rebuilt pak.  The Python tool
/// keeps `replacements.json` and `custom_slots.json` in sync via its UI; the
/// Flutter port simply consumes whatever both files say (slice 4 will add
/// the editor UI that writes them).
class CustomSlotsDataSource {
  final String workingDir;

  CustomSlotsDataSource(this.workingDir);

  String get filePath => p.join(workingDir, 'custom_slots.json');

  /// Returns a map keyed by DataTable name → ordered list of [SlotData].
  /// Missing file or empty file → empty map.  Malformed entries are skipped
  /// individually (don't fail the whole load just because one slot has a
  /// type mismatch from a hand-edited file).
  Future<Map<String, List<SlotData>>> load() async {
    final f = File(filePath);
    if (!await f.exists()) return const {};
    final src = await f.readAsString();
    if (src.trim().isEmpty) return const {};

    final decoded = jsonDecode(src);
    if (decoded is! Map) {
      throw const FormatException(
          'custom_slots.json root must be a JSON object');
    }

    final out = <String, List<SlotData>>{};
    for (final entry in decoded.entries) {
      final dtName = entry.key as String;
      final list = entry.value;
      if (list is! List) continue;
      final slots = <SlotData>[];
      for (final item in list) {
        if (item is! Map) continue;
        final slot = _slotFromJson(item);
        if (slot != null) slots.add(slot);
      }
      if (slots.isNotEmpty) out[dtName] = slots;
    }
    return out;
  }

  static SlotData? _slotFromJson(Map<dynamic, dynamic> m) {
    final bkgTex = m['bkg_tex'];
    final pnName = m['pn_name'];
    if (bkgTex is! String || bkgTex.isEmpty) return null;
    if (pnName is! String) return null;
    final subTex = m['sub_tex'];
    return SlotData(
      bkgTex: bkgTex,
      pnName: pnName,
      ls: (m['ls'] as num?)?.toInt() ?? 0,
      lsc: (m['lsc'] as num?)?.toInt() ?? 4,
      sku: (m['sku'] as num?)?.toInt() ?? 0,
      ntu: m['ntu'] as bool? ?? false,
      subTex: subTex is String && subTex.isNotEmpty ? subTex : null,
    );
  }
}
