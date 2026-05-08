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

  const AppConfig({
    required this.texconv,
    required this.repak,
    required this.baseGamePak,
    required this.modsFolder,
  });

  const AppConfig.empty()
      : texconv = '',
        repak = '',
        baseGamePak = '',
        modsFolder = '';

  AppConfig copyWith({
    String? texconv,
    String? repak,
    String? baseGamePak,
    String? modsFolder,
  }) {
    return AppConfig(
      texconv: texconv ?? this.texconv,
      repak: repak ?? this.repak,
      baseGamePak: baseGamePak ?? this.baseGamePak,
      modsFolder: modsFolder ?? this.modsFolder,
    );
  }

  bool get hasRepak => repak.isNotEmpty;
  bool get hasModsFolder => modsFolder.isNotEmpty;

  /// True when every required path is set, points at a real file/dir, AND
  /// the tool/pak fields carry the expected basename (so a swapped
  /// texconv↔repak entry doesn't silently pass).  Drives the launch-time
  /// check that decides whether to pop the SetupDialog.
  bool get isReady {
    return isFileWithExpectedName(texconv, kTexconvBasename) &&
        isFileWithExpectedName(repak, kRepakBasename) &&
        isFileWithExpectedName(baseGamePak, kBaseGamePakBasename) &&
        modsFolder.isNotEmpty &&
        _dirExists(modsFolder);
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
