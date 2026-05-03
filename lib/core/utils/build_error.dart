/// Build error codes ported verbatim from RR_VHS_Tool.py:497-513.
///
/// The Python tool surfaces these codes in the build log so users can search
/// the project wiki by code rather than by translated message. Dart-side we
/// keep the same code → message mapping; messages are English-only to match
/// the Python source.
library;

class BuildError implements Exception {
  final String code;
  final String message;
  final Object? cause;

  const BuildError(this.code, this.message, {this.cause});

  @override
  String toString() => '[$code] $message';
}

const Map<String, String> kBuildErrorMessages = {
  'E001': 'texconv.exe not found or failed to convert image',
  'E002': 'Image file could not be read or is corrupted',
  'E003': 'T_Bkg texture clone failed (uasset patching error)',
  'E004': 'DataTable build failed (name table or row construction error)',
  'E005': 'DataTable serial_size mismatch (row size or header error)',
  'E006': 'New Release DataTable build failed',
  'E007': 'Standee blueprint clone failed',
  'E008': 'Material Instance creation failed',
  'E009': 'repak pack command failed',
  'E010': 'Could not copy pak to ~mods folder (file locked)',
  'E011': 'AssetRegistry.bin extraction failed',
  'E012': 'Base game pak file not accessible',
  'E013': 'T_Sub transparent texture injection failed',
  'E014': 'New Release texture clone failed (cross-genre)',
  'E015': 'Game update detected — row size or structure changed',
};

BuildError buildError(String code, {Object? cause, String? extra}) {
  final base = kBuildErrorMessages[code] ?? 'Unknown error';
  final msg = extra == null ? base : '$base: $extra';
  return BuildError(code, msg, cause: cause);
}
