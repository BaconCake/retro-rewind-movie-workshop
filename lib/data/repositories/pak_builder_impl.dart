import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../core/utils/build_error.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/build_result.dart';
import '../../domain/repositories/pak_builder.dart';
import '../datatable/datatable_builder.dart';
import '../datatable/datatable_manager.dart';
import '../services/pak_cache.dart';

/// Build pipeline. Mirrors the Python `_build()` flow in RR_VHS_Tool.py:14134.
/// Slice 2c-D wires the full DataTable rebuild path: base-game slots are
/// decoded, re-synthesised, and written into the work tree alongside
/// AssetRegistry. The output pak now contains real Unreal DataTable assets
/// (one row per slot, vs the base game's 77 rows per slot).
class PakBuilderImpl implements PakBuilder {
  final String workingDir;
  final PakCache _pakCache;
  late final DataTableManager _dataTables;
  final _logController = StreamController<String>.broadcast();

  PakBuilderImpl(this.workingDir) : _pakCache = PakCache(workingDir) {
    _dataTables = DataTableManager(DataTableBuilder(_pakCache));
  }

  PakCache get pakCache => _pakCache;

  @override
  Stream<String> get logStream => _logController.stream;

  void _log(String line) {
    _logController.add('[Build] $line');
  }

  @override
  Future<BuildResult> build(AppConfig config) async {
    _log('Starting build (Flutter port $kFlutterBuildVersion)');

    // Validate config — the buttons in the UI check this too, but a CLI/test
    // entry point should fail loudly.
    if (!config.hasRepak || !File(config.repak).existsSync()) {
      return _fail('E009', 'repak.exe path missing or invalid: "${config.repak}"');
    }
    if (config.baseGamePak.isNotEmpty && !File(config.baseGamePak).existsSync()) {
      return _fail('E012', 'base_game_pak does not exist: "${config.baseGamePak}"');
    }

    // Set up the work dir as <workingDir>/build_work/RetroRewind/.
    // repak pack expects a folder whose contents become the pak's root.
    final workRoot = Directory(p.join(workingDir, 'build_work'));
    final retroRewindDir =
        Directory(p.join(workRoot.path, 'RetroRewind'));
    try {
      if (await workRoot.exists()) {
        await workRoot.delete(recursive: true);
      }
      await retroRewindDir.create(recursive: true);
    } catch (e) {
      return _fail('E009', 'Could not prepare work directory: $e');
    }
    _log('Work dir: ${workRoot.path}');

    // Extract AssetRegistry.bin from base pak and copy into work tree.
    // Non-fatal: Python emits [E011] as a warning and continues the build
    // (RR_VHS_Tool.py:14128-14132).
    const arInternal = 'RetroRewind/AssetRegistry.bin';
    final ar = await _pakCache.extractFile(config, arInternal);
    if (ar.ok) {
      final dst = p.join(workRoot.path, 'RetroRewind', 'AssetRegistry.bin');
      await Directory(p.dirname(dst)).create(recursive: true);
      await File(ar.path!).copy(dst);
      _log('AssetRegistry.bin included (${(ar.sizeBytes! / 1024).round()} KB)');
    } else {
      _log('WARNING: ${ar.warning}');
    }

    // Build all 13 DataTables: base game slots → re-synthesised uasset+uexp
    // pairs. With no title overrides this is a "no-op" rebuild — the pak
    // contains structurally-fresh DataTables that should still load and
    // present the same movies in-game. Once UI for editing is added, the
    // overrides parameter is where user changes flow in.
    final dtDir =
        Directory(p.join(workRoot.path, kDataTableRootPath));
    await dtDir.create(recursive: true);
    try {
      final results = await _dataTables.buildAll(
        config,
        log: (dt, msg) => _log('DataTable[$dt]: $msg'),
      );
      for (final entry in results.entries) {
        final dt = entry.key;
        final r = entry.value;
        await File(p.join(dtDir.path, '$dt.uasset'))
            .writeAsBytes(r.uassetBytes);
        await File(p.join(dtDir.path, '$dt.uexp'))
            .writeAsBytes(r.uexpBytes);
      }
      _log('Wrote ${results.length} DataTables to ${dtDir.path}');
    } on DataTableBuildError catch (e) {
      return _fail(e.code, '${e.dataTableName}: ${e.message}');
    } catch (e) {
      return _fail('E004', 'DataTable build threw: $e');
    }

    // Output pak path (next to working dir, like Python's OUTPUT_DIR).
    final pakPath = p.join(workingDir, kOutputPakFilename);

    _log('Running: repak pack --version V11');
    final ProcessResult res;
    try {
      res = await Process.run(
        config.repak,
        ['pack', '--version', 'V11', workRoot.path, pakPath],
      );
    } catch (e) {
      return _fail('E009', 'repak invocation threw: $e');
    }

    if (res.exitCode != 0) {
      final stderr = (res.stderr ?? '').toString().trim();
      return _fail('E009',
          'repak exit ${res.exitCode}${stderr.isEmpty ? '' : ': $stderr'}');
    }

    final pakFile = File(pakPath);
    if (!await pakFile.exists()) {
      return _fail('E009', 'repak reported success but pak file is missing');
    }
    final size = await pakFile.length();
    _log('Pak built: ${(size / (1024 * 1024)).toStringAsFixed(2)} MB');

    // Install — copy to mods folder with a small retry loop because Steam or
    // the running game can briefly hold an open handle on the file.
    String? installedPath;
    if (config.hasModsFolder) {
      final modsDir = Directory(config.modsFolder);
      if (!await modsDir.exists()) {
        return _fail('E010',
            'mods_folder does not exist: "${config.modsFolder}"');
      }
      final dst = p.join(config.modsFolder, kOutputPakFilename);
      installedPath = await _copyWithRetry(pakPath, dst);
      if (installedPath == null) {
        return _fail('E010',
            'Could not copy pak to ~mods (file may be locked by the game)');
      }
      _log('Installed to: $installedPath');
    } else {
      _log('mods_folder not configured — pak built but not installed');
    }

    return BuildResult.ok(
      pakPath: pakPath,
      installedPath: installedPath,
      pakSizeBytes: size,
    );
  }

  Future<String?> _copyWithRetry(String src, String dst) async {
    // Mirrors the Python retry loop (RR_VHS_Tool.py:14145-14151): up to 10
    // attempts with a short delay between each.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await File(src).copy(dst);
        return dst;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return null;
  }

  BuildResult _fail(String code, String extra) {
    final err = buildError(code, extra: extra);
    _log(err.toString());
    return BuildResult.failure(code: code, message: err.message);
  }

  void dispose() {
    _logController.close();
  }
}
