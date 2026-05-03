import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/entities/texture_replacement.dart';

/// Reads / writes `replacements.json` next to the Flutter executable, matching
/// the Python tool's `REPLACE_FILE` location (RR_VHS_Tool.py:554).
///
/// File format: top-level JSON object keyed by texture name (e.g.
/// `T_Bkg_Hor_001`), value is either a path string or a full
/// `TextureReplacement` map.  See `TextureReplacement.fromJson` for the
/// per-entry contract.
class ReplacementsDataSource {
  /// Directory holding `replacements.json`.  In production this is the
  /// directory containing the .exe; during `flutter run` it is the project
  /// root (whichever is the build/working directory).
  final String workingDir;

  ReplacementsDataSource(this.workingDir);

  String get filePath => p.join(workingDir, 'replacements.json');

  /// Load the current replacements.  Returns an empty map (no entries) if
  /// the file is absent — matching Python's behaviour of starting fresh
  /// when no `replacements.json` exists yet.
  Future<Map<String, TextureReplacement>> load() async {
    final f = File(filePath);
    if (!await f.exists()) return <String, TextureReplacement>{};
    final src = await f.readAsString();
    if (src.trim().isEmpty) return <String, TextureReplacement>{};
    return TextureReplacement.mapFromJsonString(src);
  }

  Future<void> save(Map<String, TextureReplacement> entries) async {
    final f = File(filePath);
    await f.writeAsString(TextureReplacement.mapToJsonString(entries));
  }
}
