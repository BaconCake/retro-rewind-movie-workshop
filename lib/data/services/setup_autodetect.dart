import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart'
    show kBaseGamePakBasename, kTexconvBasename, kRepakBasename;

/// Outcome bucket for a single field after an AUTO-DETECT press.  Mirrors
/// Python's `_auto_detect_tools` 3-state classification
/// (RR_VHS_Tool.py:7181-7236): newly-found vs already-set vs still-blank.
enum AutoDetectFieldClass {
  /// Field was empty before the press and detection filled it.
  newlyFound,

  /// Field already had a value before the press; we never overwrite, so
  /// this is true regardless of whether detection found one too.
  alreadyConfigured,

  /// Field was empty and detection could not resolve it.  Drives the
  /// orange "browse manually" hint + flash-on-retry escalation.
  stillMissing,
}

/// Aggregated outcome for a subgroup (tools = texconv+repak,
/// game = basePak+modsFolder).  `missing` if any field in the subgroup is
/// still missing; otherwise `newlyResolved` if at least one was just
/// found, else `alreadyConfigured`.
enum AutoDetectSubgroupOutcome {
  newlyResolved,
  alreadyConfigured,
  missing,
}

/// Per-press classification of an AUTO-DETECT result.  Pure value object,
/// safe to test in isolation.  The SetupDialog uses this to render the
/// inline status panel and decide when to escalate to a flash.
class AutoDetectClassification {
  final AutoDetectFieldClass texconv;
  final AutoDetectFieldClass repak;
  final AutoDetectFieldClass basePak;
  final AutoDetectFieldClass modsFolder;

  /// `tools` covers texconv + repak; `game` covers basePak + modsFolder.
  final AutoDetectSubgroupOutcome toolsOutcome;
  final AutoDetectSubgroupOutcome gameOutcome;

  /// Human-readable names of the still-missing fields per subgroup, in
  /// stable order.  Empty list when the subgroup resolved.
  final List<String> toolsMissingLabels;
  final List<String> gameMissingLabels;

  const AutoDetectClassification({
    required this.texconv,
    required this.repak,
    required this.basePak,
    required this.modsFolder,
    required this.toolsOutcome,
    required this.gameOutcome,
    required this.toolsMissingLabels,
    required this.gameMissingLabels,
  });

  bool get anyMissing =>
      toolsOutcome == AutoDetectSubgroupOutcome.missing ||
      gameOutcome == AutoDetectSubgroupOutcome.missing;
}

/// Classify the outcome of one AUTO-DETECT press given the field state
/// snapshot taken BEFORE the press and the detection result.  Caller is
/// responsible for actually applying detection (only filling empty
/// fields) — this function just labels what happened.
///
/// Pure port of the classification embedded in Python's
/// `_auto_detect_tools` (7181-7236) and `_auto_detect_game` (7238-7343).
AutoDetectClassification classifyAutoDetect({
  required String beforeTexconv,
  required String beforeRepak,
  required String beforeBasePak,
  required String beforeModsFolder,
  required SetupAutoDetectResult detected,
}) {
  AutoDetectFieldClass classify(String before, String? found) {
    if (before.isNotEmpty) return AutoDetectFieldClass.alreadyConfigured;
    if (found != null) return AutoDetectFieldClass.newlyFound;
    return AutoDetectFieldClass.stillMissing;
  }

  AutoDetectSubgroupOutcome aggregate(List<AutoDetectFieldClass> fields) {
    if (fields.contains(AutoDetectFieldClass.stillMissing)) {
      return AutoDetectSubgroupOutcome.missing;
    }
    if (fields.contains(AutoDetectFieldClass.newlyFound)) {
      return AutoDetectSubgroupOutcome.newlyResolved;
    }
    return AutoDetectSubgroupOutcome.alreadyConfigured;
  }

  final tx = classify(beforeTexconv, detected.texconv);
  final rp = classify(beforeRepak, detected.repak);
  final bp = classify(beforeBasePak, detected.baseGamePak);
  final mf = classify(beforeModsFolder, detected.modsFolder);

  return AutoDetectClassification(
    texconv: tx,
    repak: rp,
    basePak: bp,
    modsFolder: mf,
    toolsOutcome: aggregate([tx, rp]),
    gameOutcome: aggregate([bp, mf]),
    toolsMissingLabels: [
      if (tx == AutoDetectFieldClass.stillMissing) kTexconvBasename,
      if (rp == AutoDetectFieldClass.stillMissing) kRepakBasename,
    ],
    gameMissingLabels: [
      if (bp == AutoDetectFieldClass.stillMissing) 'game pak file',
      if (mf == AutoDetectFieldClass.stillMissing) 'mods folder',
    ],
  );
}

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

  /// Resolve a user-picked path into `(basePak, modsFolder)` regardless of
  /// which level of the install they pointed at.  Mirrors Python's
  /// `_browse_game_folder` heuristic (RR_VHS_Tool.py:7368-7392): the user
  /// can pick any of the game root, `RetroRewind/`, `Content/Paks/`, or
  /// the pak file itself — the tool figures out the rest.
  ///
  /// Returns null fields when no `RetroRewind-Windows.pak` is reachable
  /// under the picked path.  Caller decides how to surface that
  /// (snackbar, status row, etc.).
  static ({String? baseGamePak, String? modsFolder})
      resolveGameFolderPick(String pickedPath) {
    if (pickedPath.isEmpty) return (baseGamePak: null, modsFolder: null);

    // (1) Picked a file — must be the pak itself.
    if (File(pickedPath).existsSync()) {
      if (p.basename(pickedPath).toLowerCase() ==
          kBaseGamePakBasename.toLowerCase()) {
        return (
          baseGamePak: pickedPath,
          modsFolder: deriveModsFolder(pickedPath),
        );
      }
      return (baseGamePak: null, modsFolder: null);
    }

    // (2) Picked a directory — try every level relative to the pak.
    if (!Directory(pickedPath).existsSync()) {
      return (baseGamePak: null, modsFolder: null);
    }
    final candidates = [
      pickedPath,                                              // .../Paks
      p.join(pickedPath, 'Content', 'Paks'),                   // .../RetroRewind (inner)
      p.join(pickedPath, 'RetroRewind', 'Content', 'Paks'),    // <game> (outer RR)
    ];
    for (final dir in candidates) {
      final pak = p.join(dir, kBaseGamePakBasename);
      if (File(pak).existsSync()) {
        return (baseGamePak: pak, modsFolder: deriveModsFolder(pak));
      }
    }
    return (baseGamePak: null, modsFolder: null);
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
