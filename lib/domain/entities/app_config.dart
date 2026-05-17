import 'dart:io';

import 'package:path/path.dart' as p;

/// Required basenames for each tool path.  Validating against these stops
/// the user from putting `repak.exe` in the texconv field (or vice versa)
/// in the SetupDialog, which would silently break the build.
const String kTexconvBasename = 'texconv.exe';
const String kRepakBasename = 'repak.exe';
const String kBaseGamePakBasename = 'RetroRewind-Windows.pak';

/// True when [path] is a real file AND its basename matches [expected]
/// (case-insensitive — Windows is forgiving on filename casing).
bool isFileWithExpectedName(String path, String expected) {
  if (path.isEmpty) return false;
  if (!_fileExists(path)) return false;
  return p.basename(path).toLowerCase() == expected.toLowerCase();
}

/// Configuration loaded from config.json. Mirrors the Python tool's schema
/// (RR_VHS_Tool.py:2262-2277) — same field names so users can switch tools
/// without re-entering paths.
class AppConfig {
  final String texconv;
  final String repak;
  final String baseGamePak;
  final String modsFolder;

  /// Opt-in extra logging / diagnostics surface.  Python persists this
  /// alongside the path fields (RR_VHS_Tool.py:6878-6885, default false).
  /// Currently exposed via the SetupDialog checkbox; reading-side wiring
  /// is the caller's responsibility (no behaviour change in pak builder
  /// today — see M2 audit M7).
  final bool devMode;

  const AppConfig({
    required this.texconv,
    required this.repak,
    required this.baseGamePak,
    required this.modsFolder,
    this.devMode = false,
  });

  const AppConfig.empty()
      : texconv = '',
        repak = '',
        baseGamePak = '',
        modsFolder = '',
        devMode = false;

  AppConfig copyWith({
    String? texconv,
    String? repak,
    String? baseGamePak,
    String? modsFolder,
    bool? devMode,
  }) {
    return AppConfig(
      texconv: texconv ?? this.texconv,
      repak: repak ?? this.repak,
      baseGamePak: baseGamePak ?? this.baseGamePak,
      modsFolder: modsFolder ?? this.modsFolder,
      devMode: devMode ?? this.devMode,
    );
  }

  bool get hasRepak => repak.isNotEmpty;
  bool get hasModsFolder => modsFolder.isNotEmpty;

  /// Clear paths whose targets no longer exist on disk — defensive against
  /// `config.json` copied between machines or after a game/tool reinstall.
  /// Pure port of Python's `load_config` post-read clean
  /// (RR_VHS_Tool.py:2715-2719).
  ///
  /// File-typed fields (texconv/repak/baseGamePak) clear when no file
  /// exists at the path; directory-typed `modsFolder` clears when no
  /// directory exists.  Empty fields are passed through unchanged.
  AppConfig withClearedStalePaths() {
    return AppConfig(
      texconv: texconv.isEmpty || _fileExists(texconv) ? texconv : '',
      repak: repak.isEmpty || _fileExists(repak) ? repak : '',
      baseGamePak:
          baseGamePak.isEmpty || _fileExists(baseGamePak) ? baseGamePak : '',
      modsFolder:
          modsFolder.isEmpty || _dirExists(modsFolder) ? modsFolder : '',
      devMode: devMode,
    );
  }

  /// True when every required path is set, points at a real file/dir, AND
  /// the tool/pak fields carry the expected basename (so a swapped
  /// texconv↔repak entry doesn't silently pass).  Drives the launch-time
  /// check that decides whether to pop the SetupDialog.
  bool get isReady => missingFields.isEmpty;

  /// Human-readable names of the fields blocking [isReady], in stable
  /// order (texconv → repak → pak → mods).  Mirrors Python's
  /// `_update_all_status` missing list (RR_VHS_Tool.py:6970): the
  /// SetupDialog renders this on the disabled Save button instead of a
  /// generic "fill in all fields" placeholder so the user sees at a
  /// glance which fields still need attention.
  List<String> get missingFields {
    return [
      if (!isFileWithExpectedName(texconv, kTexconvBasename)) kTexconvBasename,
      if (!isFileWithExpectedName(repak, kRepakBasename)) kRepakBasename,
      if (!isFileWithExpectedName(baseGamePak, kBaseGamePakBasename))
        'game pak file',
      if (modsFolder.isEmpty || !_dirExists(modsFolder)) 'mods folder',
    ];
  }
}

bool _fileExists(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

bool _dirExists(String path) {
  try {
    return Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}
