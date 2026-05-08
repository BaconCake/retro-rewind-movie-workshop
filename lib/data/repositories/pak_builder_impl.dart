import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../core/constants/new_release.dart';
import '../../core/utils/build_error.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/build_result.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/repositories/pak_builder.dart';
import '../../core/constants/tsub_template.dart';
import '../datasources/custom_slots_data_source.dart';
import '../datasources/nr_slots_data_source.dart';
import '../datasources/replacements_data_source.dart';
import '../datatable/datatable_builder.dart';
import '../datatable/datatable_manager.dart';
import '../datatable/newrelease_datatable_builder.dart';
import '../datatable/slot_data.dart';
import '../datatable/standee_blueprint_cloner.dart';
import '../datatable/standee_mi_builder.dart';
import '../datatable/standee_templates.dart';
import '../datatable/standee_thumbnail_builder.dart';
import '../services/pak_cache.dart';
import '../services/transparent_tsub_builder.dart';
import 'texture_injector_impl.dart';

/// Maximum number of injects in flight at once.  Each inject spawns a
/// worker isolate that runs the pure-Dart prepare (cubic resize + PNG
/// encode) AND the texconv subprocess; both are CPU-bound, so the main
/// limit is core count.  Defaulting to 6 — a sweet spot on typical
/// 8-core dev machines that still leaves cores for the UI isolate +
/// the Windows subprocess plumbing.
const int _kInjectParallelism = 6;

class _InjectTask {
  final String name;
  final String genreCode;
  final TextureReplacement? replacement;
  const _InjectTask(
      {required this.name, required this.genreCode, this.replacement});
}

enum _InjectOutcome { injected, placeholder, failed }

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
  late final NrSlotsDataSource _nrSlotsDataSource;
  late final NewReleaseDataTableBuilder _nrDtBuilder;
  late final StandeeBlueprintCloner _blueprintCloner;
  final _logController = StreamController<String>.broadcast();
  final _progressController = StreamController<BuildProgress>.broadcast();
  int _progressCurrent = 0;
  int _progressTotal = 0;

  PakBuilderImpl(this.workingDir) : _pakCache = PakCache(workingDir) {
    _dataTables = DataTableManager(DataTableBuilder(_pakCache));
    _injector = TextureInjectorImpl(pakCache: _pakCache);
    _replacementsDataSource = ReplacementsDataSource(workingDir);
    _customSlotsDataSource = CustomSlotsDataSource(workingDir);
    _nrSlotsDataSource = NrSlotsDataSource(workingDir);
    _nrDtBuilder = NewReleaseDataTableBuilder(_pakCache);
    _blueprintCloner = StandeeBlueprintCloner(_pakCache);
  }

  PakCache get pakCache => _pakCache;

  @override
  Stream<String> get logStream => _logController.stream;

  @override
  Stream<BuildProgress> get progressStream => _progressController.stream;

  void _log(String line) {
    _logController.add('[Build] $line');
  }

  /// Emit one tick of progress with the given [label] (description of the
  /// unit of work that just completed).  Total is set up front in build();
  /// this just advances current by 1.
  void _step(String label) {
    _progressCurrent++;
    _progressController.add(BuildProgress(
      current: _progressCurrent.clamp(0, _progressTotal),
      total: _progressTotal,
      label: label,
    ));
  }

  /// Called once at the very start of build() so the UI can render an
  /// empty bar before any work has happened.
  void _initProgress(int total) {
    _progressCurrent = 0;
    _progressTotal = total;
    _progressController.add(BuildProgress(
      current: 0,
      total: total,
      label: 'Starting…',
    ));
  }

  /// Run [body] under a phase label and accumulate the elapsed time into
  /// [timings].  The dump at the end of [build] reports all phases sorted
  /// by cost so it's obvious where the slow ones are.
  Future<T> _phase<T>(String label, Map<String, int> timings,
      Future<T> Function() body) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      timings[label] = (timings[label] ?? 0) + sw.elapsedMilliseconds;
    }
  }

  @override
  Future<BuildResult> build(AppConfig config) async {
    final overall = Stopwatch()..start();
    final timings = <String, int>{};
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

    // Load all three per-machine state files up front so we can size the
    // progress bar correctly.  Python keeps replacements + custom_slots in
    // lockstep via its UI; the Flutter port just consumes whatever's on
    // disk.
    final replacements = await _safeLoadReplacements();
    final customSlots = await _safeLoadCustomSlots();
    final nrSlots = await _safeLoadNrSlots();

    // Compute total progress units before any work starts.  Each unit is
    // one observable thing the UI can announce: AR + DTs + per-slot
    // injects + per-NR standees + NR cover injects + T_Subs + repak +
    // install.  Genre slots dominate the wall-clock so they dominate
    // the bar — proportional to actual time spent.
    final genreSlotCount = customSlots.values
        .expand((l) => l)
        .where((s) => s.bkgTex.startsWith('T_Bkg_'))
        .length;
    final eligibleNrSlots = [
      for (final s in nrSlots) if (kNrGenreByte.containsKey(s.genre)) s,
    ];
    final nrCoverSlots = eligibleNrSlots
        .where((s) => replacements.containsKey(s.bkgTex))
        .length;
    final progressTotal = 1 // AR
        + customSlots.length // one per genre DataTable
        + genreSlotCount // genre injects
        + (eligibleNrSlots.isNotEmpty ? 1 : 0) // NR DT
        + eligibleNrSlots.length * 3 // per-NR: MI + thumb + blueprint
        + nrCoverSlots // NR cover injects
        + 1 // T_Subs
        + 1 // repak pack
        + 1; // install
    _initProgress(progressTotal);

    if (customSlots.isEmpty) {
      _log('No custom_slots.json entries — pak will be a no-op '
          '(AssetRegistry only).');
    }

    // Extract AssetRegistry.bin from base pak and copy into work tree.
    // Non-fatal: Python emits [E011] as a warning and continues the build
    // (RR_VHS_Tool.py:14128-14132).
    await _phase('AssetRegistry extract', timings, () async {
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
      _step('AssetRegistry extracted');
    });

    // Build DataTables only for genres present in customSlots.  The manager
    // skips any genre without an override (CUSTOM_ONLY_MODE).
    final dtDir =
        Directory(p.join(workRoot.path, kDataTableRootPath));
    await dtDir.create(recursive: true);
    try {
      await _phase('Genre DataTables', timings, () async {
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
          _step('DataTable $dt');
        }
        _log('Wrote ${results.length} custom DataTables to ${dtDir.path}');
      });
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
    await _phase('Genre textures', timings, () =>
        _writeTextures(config, workRoot.path, customSlots, replacements));

    // Build NewRelease DataTable + per-NR standee assets.  Slots come from
    // nr_custom_slots.json (loaded next to the executable, same convention
    // as custom_slots.json).  When the file is empty, the whole NR step is
    // skipped — the in-game New Releases shelf falls back to the base game.
    if (nrSlots.isNotEmpty) {
      try {
        await _phase('NR DT + standees', timings, () =>
            _writeNrAssets(config, workRoot.path, nrSlots));
      } on NewReleaseBuildError catch (e) {
        return _fail(e.code, 'NewRelease DT: ${e.message}');
      } catch (e) {
        return _fail('E004', 'NewRelease build threw: $e');
      }
      // Custom NR cover textures (T_New_*).  Only fires for slots with a
      // replacement entry — slots without a cover let the engine fall back
      // to the base game's NR texture (which is fine for genres with
      // newCount>0 and acceptable as a "no cover yet" state).
      await _phase('NR textures', timings, () =>
          _writeNrTextures(config, workRoot.path, nrSlots, replacements));
    } else {
      _log('No NR slots — skipping New Release DT + standees');
    }

    // Inject the always-transparent T_Sub batch.  Without this the base
    // game's procedural subject artwork remains visible on top of every
    // cover.  We always emit T_Sub_01..T_Sub_77, plus any T_Sub_78+ names
    // referenced by a custom slot's sub_tex field.  All identical
    // transparent images so sharing names across slots is safe.
    // RR_VHS_Tool.py:14007-14060.
    await _phase('T_Sub writes', timings, () =>
        _writeTransparentSubjects(workRoot.path, customSlots));
    _step('Transparent T_Subs');

    // Output pak path (next to working dir, like Python's OUTPUT_DIR).
    final pakPath = p.join(workingDir, kOutputPakFilename);

    _log('Running: repak pack --version V11');
    final ProcessResult res;
    try {
      res = await _phase('repak pack', timings, () => Process.run(
            config.repak,
            ['pack', '--version', 'V11', workRoot.path, pakPath],
          ));
    } catch (e) {
      return _fail('E009', 'repak invocation threw: $e');
    }
    _step('Pak built');

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
      installedPath = await _phase('install', timings, () => _copyWithRetry(pakPath, dst));
      if (installedPath == null) {
        return _fail('E010',
            'Could not copy pak to ~mods (file may be locked by the game)');
      }
      _log('Installed to: $installedPath');
      _step('Installed');
    } else {
      _log('mods_folder not configured — pak built but not installed');
      _step('Skipped install');
    }

    overall.stop();
    _logTimings(timings, overall.elapsedMilliseconds);

    return BuildResult.ok(
      pakPath: pakPath,
      installedPath: installedPath,
      pakSizeBytes: size,
    );
  }

  /// Pretty-print phase timings sorted by cost so the slow ones jump out.
  void _logTimings(Map<String, int> timings, int totalMs) {
    _log('━━━ Build summary (${(totalMs / 1000).toStringAsFixed(2)}s) ━━━');
    final sorted = timings.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxLabelLen =
        sorted.fold<int>(0, (m, e) => e.key.length > m ? e.key.length : m);
    for (final e in sorted) {
      final pct = totalMs > 0 ? (e.value * 100 / totalMs).round() : 0;
      _log('  ${e.key.padRight(maxLabelLen)}  '
          '${(e.value / 1000).toStringAsFixed(2)}s  ($pct%)');
    }
    final accounted = timings.values.fold<int>(0, (a, b) => a + b);
    final unaccounted = totalMs - accounted;
    if (unaccounted > 50) {
      _log('  ${"(other)".padRight(maxLabelLen)}  '
          '${(unaccounted / 1000).toStringAsFixed(2)}s');
    }
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

  Future<List<NewReleaseSlot>> _safeLoadNrSlots() async {
    try {
      return await _nrSlotsDataSource.load();
    } catch (e) {
      _log('Skipping NR slots: nr_custom_slots.json unreadable ($e)');
      return const [];
    }
  }

  /// Build + write every NR-related asset for the given [slots]:
  ///
  ///   * NewRelease_Details_-_Data DataTable (1 file pair).
  ///   * Per-slot trio: MI uasset+uexp, thumbnail uasset+uexp, blueprint
  ///     uasset+uexp.
  ///
  /// All file paths live under [workRoot]/[NewReleaseBuildResult.relativePath]
  /// with `.uasset`/`.uexp` suffixes.  Failures of individual standee assets
  /// are logged and counted but do not abort the build — a missing standee
  /// degrades gracefully in-game (no popup model, but the shelf still shows
  /// the NR cover).  A failure of the NR DT itself is fatal because then
  /// the engine has no row referencing the standee at all.
  Future<void> _writeNrAssets(
      AppConfig config,
      String workRoot,
      List<NewReleaseSlot> slots) async {
    _log('Building NewRelease DT + standees for ${slots.length} slot(s)...');

    // Apply the same filter the NR DT builder uses, so we don't try to
    // build standee assets for slots whose row was dropped from the DT.
    final validSlots = [
      for (final s in slots)
        if (kNrGenreByte.containsKey(s.genre)) s,
    ];
    if (validSlots.length < slots.length) {
      _log('  NR DT: ${slots.length - validSlots.length} slot(s) filtered '
          '(unsupported genre)');
    }
    if (validSlots.isEmpty) {
      _log('  NR DT: no valid slots after filter — skipping');
      return;
    }

    // 1) NR DataTable.
    final dtResult = await _nrDtBuilder.build(config, validSlots);
    if (dtResult == null) {
      _log('  NR DT: builder returned null — skipping');
      return;
    }
    final dtDir = p.join(
        workRoot, 'RetroRewind', 'Content', 'VideoStore', 'core',
        'blueprint', 'data');
    await Directory(dtDir).create(recursive: true);
    await File(p.join(dtDir, 'NewRelease_Details_-_Data.uasset'))
        .writeAsBytes(dtResult.uassetBytes);
    await File(p.join(dtDir, 'NewRelease_Details_-_Data.uexp'))
        .writeAsBytes(dtResult.uexpBytes);
    _log('  NR DT: ${dtResult.rowCount} row(s) written');
    _step('NR DataTable');

    // 2) Per-slot standee assets.  Load templates once.
    final StandeeTemplates templates;
    try {
      templates = await StandeeTemplates.load();
    } catch (e) {
      _log('  Standees SKIP all: template load failed ($e)');
      return;
    }
    final miBuilder = StandeeMiBuilder(templates);
    final thumbBuilder = StandeeThumbnailBuilder(templates, config);

    var miOk = 0, thumbOk = 0, bpOk = 0, fail = 0;
    for (final s in validSlots) {
      // 2a) MI material instance.
      try {
        final mi = miBuilder.build(
          genreCode: s.genreCode,
          texNum: s.texNum,
          standeeShape: s.standeeShape,
        );
        await _writeAssetPair(workRoot, mi.relativePath,
            mi.uassetBytes, mi.uexpBytes);
        miOk++;
      } catch (e) {
        fail++;
        _log('  MI FAIL ${s.bkgTex}: $e');
      }
      _step('MI ${s.bkgTex}');

      // 2b) Thumbnail texture.
      try {
        final th = await thumbBuilder.build(sku: s.sku, shape: s.standeeShape);
        await _writeAssetPair(workRoot, th.relativePath,
            th.uassetBytes, th.uexpBytes);
        thumbOk++;
      } catch (e) {
        fail++;
        _log('  Thumb FAIL ${s.bkgTex}: $e');
      }
      _step('Thumb ${s.bkgTex}');

      // 2c) Standee mesh blueprint clone.
      try {
        final bp = await _blueprintCloner.clone(
          config: config,
          sku: s.sku,
          standeeShape: s.standeeShape,
          genreCode: s.genreCode,
          texNum: s.texNum,
        );
        await _writeAssetPair(workRoot, bp.relativePath,
            bp.uassetBytes, bp.uexpBytes);
        bpOk++;
      } catch (e) {
        fail++;
        _log('  Blueprint FAIL ${s.bkgTex}: $e');
      }
      _step('Blueprint ${s.bkgTex}');
    }
    _log('  Standees: $miOk MI, $thumbOk thumb, $bpOk blueprint '
        '($fail failures)');
  }

  /// Write a uasset+uexp pair under [workRoot]/[relativePath].  The
  /// directory hierarchy is created if it doesn't exist yet.
  Future<void> _writeAssetPair(String workRoot, String relativePath,
      List<int> uasset, List<int> uexp) async {
    final fullPath = p.join(workRoot, relativePath.replaceAll('/', p.separator));
    await Directory(p.dirname(fullPath)).create(recursive: true);
    await File('$fullPath.uasset').writeAsBytes(uasset);
    await File('$fullPath.uexp').writeAsBytes(uexp);
  }

  /// Inject custom T_New_* covers for the NR slots that have a replacement
  /// entry.  Slots without a replacement are skipped — see comment at the
  /// call site.  Per-slot failures log + continue (consistent with how
  /// `_writeNrAssets` handles per-slot standee failures).
  Future<void> _writeNrTextures(
      AppConfig config,
      String workRoot,
      List<NewReleaseSlot> nrSlots,
      Map<String, TextureReplacement> replacements) async {
    final eligible = [
      for (final s in nrSlots)
        if (kNrGenreByte.containsKey(s.genre) &&
            replacements.containsKey(s.bkgTex))
          s,
    ];
    if (eligible.isEmpty) {
      _log('No NR cover replacements — skipping T_New injection');
      return;
    }
    _log('Injecting ${eligible.length} NR cover texture(s) '
        '(parallelism=$_kInjectParallelism)...');
    final tasks = [
      for (final s in eligible)
        _InjectTask(
            name: s.bkgTex,
            genreCode: s.genreCode,
            replacement: replacements[s.bkgTex])
    ];

    Future<_InjectOutcome> runOne(_InjectTask t) async {
      try {
        await _injector.inject(
          config: config,
          workRoot: workRoot,
          textureName: t.name,
          genreCode: t.genreCode,
          replacement: t.replacement!,
        );
        _log('  INJECT NR  ${t.name}');
        _step('Injected NR ${t.name}');
        return _InjectOutcome.injected;
      } catch (e) {
        _log('  FAIL   NR  ${t.name}: $e');
        _step('Failed NR ${t.name}');
        return _InjectOutcome.failed;
      }
    }

    final outcomes = await _runChunked<_InjectOutcome>(
        tasks, _kInjectParallelism, runOne);
    var injected = 0, failed = 0;
    for (final o in outcomes) {
      if (o == _InjectOutcome.injected) injected++;
      if (o == _InjectOutcome.failed) failed++;
    }
    _log('NR covers: $injected injected, $failed failed');
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

    _log('Writing $totalSlots custom texture slot(s) '
        '(parallelism=$_kInjectParallelism)...');

    // Flatten the work list, dropping non-T_Bkg / unparseable entries.
    // T_New_* slots arrive via _writeNrTextures, never via customSlots.
    final tasks = <_InjectTask>[];
    for (final entry in customSlots.entries) {
      for (final slot in entry.value) {
        final name = slot.bkgTex;
        if (!name.startsWith('T_Bkg_')) {
          _log('  SKIP $name: not T_Bkg');
          continue;
        }
        final genre = parseGenreFromTextureName(name);
        if (genre == null) {
          _log('  SKIP $name: cannot parse genre');
          continue;
        }
        tasks.add(_InjectTask(
            name: name, genreCode: genre.code, replacement: replacements[name]));
      }
    }

    Future<_InjectOutcome> runOne(_InjectTask t) async {
      try {
        if (t.replacement != null) {
          await _injector.inject(
            config: config,
            workRoot: workRoot,
            textureName: t.name,
            genreCode: t.genreCode,
            replacement: t.replacement!,
          );
          _log('  INJECT      ${t.name}');
          _step('Injected ${t.name}');
          return _InjectOutcome.injected;
        } else {
          await _injector.writePlaceholder(
            config: config,
            workRoot: workRoot,
            textureName: t.name,
            genreCode: t.genreCode,
          );
          _log('  PLACEHOLDER ${t.name}');
          _step('Placeholder ${t.name}');
          return _InjectOutcome.placeholder;
        }
      } catch (e) {
        _log('  FAIL        ${t.name}: $e');
        _step('Failed ${t.name}');
        return _InjectOutcome.failed;
      }
    }

    final outcomes = await _runChunked<_InjectOutcome>(
        tasks, _kInjectParallelism, runOne);
    for (final o in outcomes) {
      switch (o) {
        case _InjectOutcome.injected:
          injected++;
        case _InjectOutcome.placeholder:
          placeholders++;
        case _InjectOutcome.failed:
          failed++;
      }
    }
    _log('Textures written: $injected injected, $placeholders placeholder, '
        '$failed failed (of $totalSlots)');
  }

  /// Run [body] over [items] with at most [concurrency] futures in flight.
  /// Order of results matches [items]; per-item exceptions must be caught
  /// inside [body] (this helper does not isolate them).
  Future<List<R>> _runChunked<R>(
      List<_InjectTask> items, int concurrency,
      Future<R> Function(_InjectTask) body) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= items.length) return;
        results[i] = await body(items[i]);
      }
    }

    final workers = [for (var i = 0; i < concurrency; i++) worker()];
    await Future.wait(workers);
    return [for (final r in results) r as R];
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
    _progressController.close();
  }
}
