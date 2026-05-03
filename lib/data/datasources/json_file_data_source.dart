import 'dart:convert';
import 'dart:io';

class JsonFileDataSource {
  /// Reads `path` as JSON. Returns `null` if the file does not exist.
  /// Re-throws if the file exists but is malformed — corrupt config should
  /// be loud, not silently reset.
  Future<Map<String, dynamic>?> readJson(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Writes `data` as JSON with 2-space indentation. Matches the Python tool's
  /// `json.dump(..., indent=2)` so diffs between Python/Flutter writes are clean.
  Future<void> writeJson(String path, Map<String, dynamic> data) async {
    const encoder = JsonEncoder.withIndent('  ');
    await File(path).writeAsString(encoder.convert(data));
  }
}
