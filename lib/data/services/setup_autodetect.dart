import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart' show kBaseGamePakBasename;

/// Outcome of [SetupAutoDetect.ensureModsFolder].
enum ModsFolderEnsureStatus { alreadyExisted, created, failed }

class ModsFolderEnsureResult {
  final ModsFolderEnsureStatus status;
  final String? error;

  const ModsFolderEnsureResult._(this.status, [this.error]);
  const ModsFolderEnsureResult.alreadyExisted()
      : this._(ModsFolderEnsureStatus.alreadyExisted);
  const ModsFolderEnsureResult.created()
      : this._(ModsFolderEnsureStatus.created);
  const ModsFolderEnsureResult.failed(String reason)
      : this._(ModsFolderEnsureStatus.failed, reason);

  bool get wasCreated => status == ModsFolderEnsureStatus.created;
  bool get existed => status == ModsFolderEnsureStatus.alreadyExisted;
  bool get isOk =>
      status == ModsFolderEnsureStatus.created ||
      status == ModsFolderEnsureStatus.alreadyExisted;
}

/// Bundle of auto-detected paths.  Any field can be null when detection
/// failed for that resource — the dialog leaves it for manual entry.
class SetupAutoDetectResult {
  final String? texconv;
  final String? repak;
  final String? baseGamePak;
  final String? modsFolder;

  const SetupAutoDetectResult({
    this.texconv,
    this.repak,
    this.baseGamePak,
    this.modsFolder,
  });
}

/// Pure helpers for the SetupDialog's auto-detect flow.  Mirrors Python's
/// scanning logic (RR_VHS_Tool.py auto-detect inside `SetupDialog`):
///   * tools live next to the executable or in a `tools/` subfolder;
///   * the game's `RetroRewind-Windows.pak` is found by walking Steam's
///     library roots (`libraryfolders.vdf`).
///
/// Windows-only for the Steam side; tool scanning works everywhere.
class SetupAutoDetect {
  /// Scan [exeDir] and its `tools/` (and `Tools/`) subfolder for the two
  /// modding tools.  Returns absolute paths when found, null otherwise.
  static ({String? texconv, String? repak}) findToolsNear(String exeDir) {
    String? texconv;
    String? repak;
    final dirs = [
      exeDir,
      p.join(exeDir, 'tools'),
      p.join(exeDir, 'Tools'),
    ];
    for (final dir in dirs) {
      if (texconv == null) {
        final f = File(p.join(dir, 'texconv.exe'));
        if (f.existsSync()) texconv = f.path;
      }
      if (repak == null) {
        final f = File(p.join(dir, 'repak.exe'));
        if (f.existsSync()) repak = f.path;
      }
    }
    return (texconv: texconv, repak: repak);
  }

  /// Find `RetroRewind-Windows.pak` by walking every Steam library root
  /// listed in the user's `libraryfolders.vdf`.  Returns the absolute path
  /// or null when the game / Steam isn't installed.
  static String? findRetroRewindPak() {
    for (final lib in _findSteamLibraries()) {
      final pak = p.join(lib, 'steamapps', 'common', 'RetroRewind',
          'RetroRewind', 'Content', 'Paks', kBaseGamePakBasename);
      if (File(pak).existsSync()) return pak;
    }
    return null;
  }

  /// Mods folder lives next to the base pak: `<paksDir>/~mods`.  Caller is
  /// responsible for creating the dir if it doesn't exist (the engine
  /// expects it to be present for any pak it loads from there).
  static String deriveModsFolder(String basePakPath) {
    return p.join(p.dirname(basePakPath), '~mods');
  }

  /// Try to `mkdir -p` [modsFolder].  Returns one of:
  ///   * `alreadyExisted` — the directory was already present.
  ///   * `created` — the directory did not exist and was created.
  ///   * `failed` — neither, plus the OSError surfaced for logging.
  ///
  /// Pure port of Python's `_set_game_folder` mkdir block
  /// (RR_VHS_Tool.py:7345-7366).  The UI uses the [created] outcome to
  /// surface a "Created" badge / SnackBar so the user knows we touched
  /// their filesystem.
  static ModsFolderEnsureResult ensureModsFolder(String modsFolder) {
    if (modsFolder.isEmpty) return ModsFolderEnsureResult.failed('empty path');
    final dir = Directory(modsFolder);
    if (dir.existsSync()) return ModsFolderEnsureResult.alreadyExisted();
    try {
      dir.createSync(recursive: true);
      return ModsFolderEnsureResult.created();
    } catch (e) {
      return ModsFolderEnsureResult.failed(e.toString());
    }
  }

  /// Run every detector and bundle the results.  modsFolder is derived
  /// from the pak when found.
  static SetupAutoDetectResult detectAll(String exeDir) {
    final tools = findToolsNear(exeDir);
    final pak = findRetroRewindPak();
    return SetupAutoDetectResult(
      texconv: tools.texconv,
      repak: tools.repak,
      baseGamePak: pak,
      modsFolder: pak != null ? deriveModsFolder(pak) : null,
    );
  }

  /// Find Steam library roots by reading `libraryfolders.vdf` from every
  /// known Steam install location.  Public for tests.
  static List<String> findSteamLibrariesFromVdfAt(String vdfPath) {
    final f = File(vdfPath);
    if (!f.existsSync()) return const [];
    return parseLibraryRoots(f.readAsStringSync());
  }

  /// Parse Steam's `libraryfolders.vdf` and return every `"path"` value.
  /// VDF is a simple nested key-value format; we only need the path lines.
  /// Steam writes Windows paths with `\\` escapes — we unescape to a single
  /// backslash.  Public for unit tests.
  static List<String> parseLibraryRoots(String vdfContents) {
    final out = <String>[];
    final re = RegExp(r'"path"\s+"([^"]+)"');
    for (final m in re.allMatches(vdfContents)) {
      out.add(m.group(1)!.replaceAll(r'\\', r'\'));
    }
    return out;
  }

  /// Read library roots from BOTH known VDF locations under [steamRoot].
  /// Modern Steam writes `config/libraryfolders.vdf`; older versions used
  /// `steamapps/libraryfolders.vdf` — both can be present and they
  /// occasionally disagree, so we union.  Public for tests.
  static List<String> readSteamVdfs(String steamRoot) {
    final libs = <String>{};
    for (final loc in [
      p.join(steamRoot, 'config', 'libraryfolders.vdf'),
      p.join(steamRoot, 'steamapps', 'libraryfolders.vdf'),
    ]) {
      libs.addAll(findSteamLibrariesFromVdfAt(loc));
    }
    return libs.toList();
  }

  /// Given a list of candidate Steam install / library paths, return every
  /// path that looks like a Steam library (has `steamapps/`) plus every
  /// library listed in any reachable VDF.  Public so tests can drive the
  /// scan against temp directories without touching real OS paths.
  static List<String> findSteamLibrariesFromCandidates(
      List<String> candidates) {
    final libs = <String>{};
    for (final root in candidates) {
      if (!Directory(root).existsSync()) continue;
      if (Directory(p.join(root, 'steamapps')).existsSync()) {
        libs.add(root);
      }
      libs.addAll(readSteamVdfs(root));
    }
    return libs.toList();
  }

  /// Cross-platform Steam library discovery.  Mirrors Python's
  /// `_auto_detect_game` scan (RR_VHS_Tool.py:7238-7343):
  ///   * Windows — every drive letter A-Z × {Program Files (x86)/Steam,
  ///     Program Files/Steam, Steam, SteamLibrary}.
  ///   * macOS   — `~/Library/Application Support/Steam`.
  ///   * Linux   — `~/.steam/steam` and `~/.local/share/Steam`.
  static List<String> _findSteamLibraries() {
    if (Platform.isWindows) {
      return findSteamLibrariesFromCandidates(_windowsSteamCandidates());
    }
    if (Platform.isMacOS) {
      return findSteamLibrariesFromCandidates(_macOSSteamCandidates());
    }
    if (Platform.isLinux) {
      return findSteamLibrariesFromCandidates(_linuxSteamCandidates());
    }
    return const [];
  }

  static List<String> _windowsSteamCandidates() {
    final out = <String>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final drive = '${String.fromCharCode(c)}:';
      out.addAll([
        '$drive\\Program Files (x86)\\Steam',
        '$drive\\Program Files\\Steam',
        '$drive\\Steam',
        '$drive\\SteamLibrary',
      ]);
    }
    return out;
  }

  static List<String> _macOSSteamCandidates() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return const [];
    return [p.join(home, 'Library', 'Application Support', 'Steam')];
  }

  static List<String> _linuxSteamCandidates() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return const [];
    return [
      p.join(home, '.steam', 'steam'),
      p.join(home, '.local', 'share', 'Steam'),
    ];
  }
}
