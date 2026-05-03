import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../core/utils/build_error.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/build_result.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/repositories/pak_builder.dart';
import '../../core/constants/tsub_template.dart';
import '../datasources/custom_slots_data_source.dart';
import '../datasources/replacements_data_source.dart';
import '../datatable/datatable_builder.dart';
import '../datatable/datatable_manager.dart';
import '../datatable/slot_data.dart';
import '../services/pak_cache.dart';
import '../services/transparent_tsub_builder.dart';
import 'texture_injector_impl.dart';

/// Build pipeline.  Mirrors the Python `_build()` flow (RR_VHS_Tool.py:13860-
/// 14150) operating in CUSTOM_ONLY_MODE: the mod pak only contains the genres
/// the user has actually customised.  Genres without `custom_slots.json`
/// entries are intentionally absent so the engine falls through to the base
/// game's DataTable for those genres.
class PakBuilderImpl implements PakBuilder {
  final String workingDir;
  final PakCache _pakCache;
  late final DataTableManager _dataTables;
  late final TextureInjectorImpl _injector;
  late final ReplacementsDataSource _replacementsDataSource;
  late final CustomSlotsDataSource _customSlotsDataSource;
  final _logController = StreamController<String>.broadcast();

  PakBuilderImpl(this.workingDir) : _pakCache = PakCache(workingDir) {
    _dataTables = DataTableManager(DataTableBuilder(_pakCache));
    _injector = TextureInjectorImpl(pakCache: _pakCache);
    _replacementsDataSource = ReplacementsDataSource(workingDir);
    _customSlotsDataSource = CustomSlotsDataSource(workingDir);
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

    // Load both per-machine state files.
    //   replacements.json — keyed by texture name → user image path + offsets.
    //   custom_slots.json — keyed by DataTable name → ordered slot metadata.
    // Python keeps the two files in lockstep via its UI; the Flutter port
    // just consumes whatever is on disk.  Slice 4 will add the editor.
    final replacements = await _safeLoadReplacements();
    final customSlots = await _safeLoadCustomSlots();

    if (customSlots.isEmpty) {
      _log('No custom_slots.json entries — pak will be a no-op '
          '(AssetRegistry only).');
    }

    // Build DataTables only for genres present in customSlots.  The manager
    // skips any genre without an override (CUSTOM_ONLY_MODE).
    final dtDir =
        Directory(p.join(workRoot.path, kDataTableRootPath));
    await dtDir.create(recursive: true);
    try {
      final results = await _dataTables.buildAll(
        config,
        slotOverrides: customSlots,
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
      _log('Wrote ${results.length} custom DataTables to ${dtDir.path}');
    } on DataTableBuildError catch (e) {
      return _fail(e.code, '${e.dataTableName}: ${e.message}');
    } catch (e) {
      return _fail('E004', 'DataTable build threw: $e');
    }

    // Write the texture files for every custom slot listed in customSlots.
    // Slots with a replacement entry get the user image (texconv'd → ubulk +
    // inline mips); slots without get the placeholder triple (cloned uasset
    // + template uexp + zero ubulk = black cover) so the row reference still
    // resolves to a real asset and doesn't render as missing.
    await _writeTextures(config, workRoot.path, customSlots, replacements);

    // Inject the always-transparent T_Sub batch.  Without this the base
    // game's procedural subject artwork remains visible on top of every
    // cover.  We always emit T_Sub_01..T_Sub_77, plus any T_Sub_78+ names
    // referenced by a custom slot's sub_tex field.  All identical
    // transparent images so sharing names across slots is safe.
    // RR_VHS_Tool.py:14007-14060.
    await _writeTransparentSubjects(workRoot.path, customSlots);

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

  Future<Map<String, TextureReplacement>> _safeLoadReplacements() async {
    try {
      return await _replacementsDataSource.load();
    } catch (e) {
      _log('Skipping replacements: replacements.json unreadable ($e)');
      return const {};
    }
  }

  Future<Map<String, List<SlotData>>> _safeLoadCustomSlots() async {
    try {
      return await _customSlotsDataSource.load();
    } catch (e) {
      _log('Skipping custom slots: custom_slots.json unreadable ($e)');
      return const {};
    }
  }

  Future<void> _writeTextures(
      AppConfig config,
      String workRoot,
      Map<String, List<SlotData>> customSlots,
      Map<String, TextureReplacement> replacements) async {
    var injected = 0;
    var placeholders = 0;
    var failed = 0;
    final totalSlots =
        customSlots.values.fold<int>(0, (a, list) => a + list.length);
    if (totalSlots == 0) return;

    _log('Writing $totalSlots custom texture slot(s)...');
    for (final entry in customSlots.entries) {
      for (final slot in entry.value) {
        final name = slot.bkgTex;
        // Slice 3 only handles `T_Bkg_*` slots.  T_New / NR will come in 3c.
        if (!name.startsWith('T_Bkg_')) {
          _log('  SKIP $name: not T_Bkg (deferred to slice 3c)');
          continue;
        }
        final genre = parseGenreFromTextureName(name);
        if (genre == null) {
          _log('  SKIP $name: cannot parse genre');
          continue;
        }
        final replacement = replacements[name];
        try {
          if (replacement != null) {
            await _injector.inject(
              config: config,
              workRoot: workRoot,
              textureName: name,
              genreCode: genre.code,
              replacement: replacement,
            );
            injected++;
            _log('  INJECT      $name');
          } else {
            await _injector.writePlaceholder(
              config: config,
              workRoot: workRoot,
              textureName: name,
              genreCode: genre.code,
            );
            placeholders++;
            _log('  PLACEHOLDER $name');
          }
        } catch (e) {
          failed++;
          _log('  FAIL        $name: $e');
        }
      }
    }
    _log('Textures written: $injected injected, $placeholders placeholder, '
        '$failed failed (of $totalSlots)');
  }

  Future<void> _writeTransparentSubjects(
      String workRoot, Map<String, List<SlotData>> customSlots) async {
    final names = <String>{...TransparentTSubBuilder.baseTSubNames()};
    for (final list in customSlots.values) {
      for (final slot in list) {
        final st = slot.subTex;
        if (st == null) continue;
        // Only T_Sub_78+ go through here (the < 78 range is base-game-style
        // and already in the always-emit set).  Names that don't fit the
        // 8-char T_Sub_NN shape get folded to T_Sub_78 by the builder.
        names.add(st);
      }
    }

    final destDir = Directory(p.join(workRoot, 'RetroRewind', 'Content',
        'VideoStore', 'asset', 'prop', 'vhs', 'Subject'));
    await destDir.create(recursive: true);

    const builder = TransparentTSubBuilder();
    final sortedNames = names.toList()..sort();
    var ok = 0;
    for (final name in sortedNames) {
      try {
        final art = builder.build(name);
        await Future.wait([
          File(p.join(destDir.path, '$name.uasset')).writeAsBytes(art.uasset),
          File(p.join(destDir.path, '$name.uexp')).writeAsBytes(art.uexp),
        ]);
        ok++;
      } catch (e) {
        _log('  T_Sub FAIL $name: $e');
      }
    }
    final customCount = sortedNames.where((n) {
      final num = int.tryParse(n.replaceFirst('T_Sub_', ''));
      return num != null && num >= kTSubCustomBase;
    }).length;
    _log('Transparent T_Subs written: $ok '
        '(${sortedNames.length - customCount} base + $customCount custom)');
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
