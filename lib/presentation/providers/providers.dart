import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../data/datasources/custom_slots_data_source.dart';
import '../../data/datasources/json_file_data_source.dart';
import '../../data/datasources/nr_slots_data_source.dart';
import '../../data/datasources/replacements_data_source.dart';
import '../../data/datatable/slot_data.dart';
import '../../data/repositories/config_repository_impl.dart';
import '../../data/repositories/pak_builder_impl.dart';
import '../../data/repositories/texture_repository_impl.dart';
import '../../data/services/cover_actions.dart';
import '../../data/services/layout_preloader.dart';
import '../../data/services/pak_cache.dart';
import '../../domain/custom_slot_naming.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/nr_slot_logic.dart';
import '../../domain/repositories/config_repository.dart';
import '../../domain/repositories/pak_builder.dart';
import '../../domain/repositories/texture_repository.dart';
import '../../domain/sku.dart';

/// The directory the app treats as its working dir.
///
/// Two scenarios to support:
///   * **dev** — `flutter run` builds the exe under `<project>/build/.../Debug/`
///     and runs it with `Directory.current` set to the project root.  The
///     user keeps their `config.json` + `*_slots.json` + `replacements.json`
///     in the project root, so we want to operate there.
///   * **prod** — a packaged install: cwd is wherever the user launched
///     from (could be anywhere), and the JSON state lives next to the
///     bundled exe.  We want the exe directory.
///
/// Heuristic: if the exe lives **inside** the cwd (always true under
/// `flutter run`), use cwd.  Otherwise use the exe's directory.  This is
/// stable regardless of which JSON files happen to exist — the previous
/// "look for config.json" probe broke first-launch when the user deleted
/// config.json (see project_dev_workdir.md memory).
final workingDirProvider = Provider<String>((ref) {
  final exe = Platform.resolvedExecutable;
  if (exe.contains('flutter_tester') || exe.endsWith('dart.exe')) {
    return Directory.current.path;
  }
  final cwd = Directory.current.path;
  if (p.isWithin(cwd, exe)) return cwd;
  return p.dirname(exe);
});

final jsonDataSourceProvider =
    Provider<JsonFileDataSource>((ref) => JsonFileDataSource());

final configRepositoryProvider = Provider<ConfigRepository>((ref) {
  return ConfigRepositoryImpl(
    ref.watch(jsonDataSourceProvider),
    ref.watch(workingDirProvider),
  );
});

final textureRepositoryProvider =
    Provider<TextureRepository>((ref) => TextureRepositoryImpl());

final pakBuilderProvider = Provider<PakBuilder>((ref) {
  final builder = PakBuilderImpl(ref.watch(workingDirProvider));
  ref.onDispose(builder.dispose);
  return builder;
});

final configFutureProvider = FutureProvider<AppConfig>((ref) {
  return ref.watch(configRepositoryProvider).load();
});

/// Shared [PakCache] instance keyed off the working directory.  Threading
/// it through Riverpod (instead of constructing per-call) lets the layout
/// preload, AssetRegistry extraction, and future PakCache callers share
/// the same `<workingDir>/.pak_cache/` extraction roots.
final pakCacheProvider = Provider<PakCache>((ref) {
  return PakCache(ref.watch(workingDirProvider));
});

/// Slice 4f: pre-decode the 5 base-game `T_Layout_NN_bc.ubulk` textures
/// into PNGs in `<workingDir>/layout_cache/` so [LayoutStylePicker]'s
/// thumbnail cards have real artwork to render.  Pure port of
/// `_start_layout_preload` (RR_VHS_Tool.py:7202-7241).
///
/// First run pays a few seconds for repak unpack + DXT1 decode + PNG
/// encode; subsequent runs are instant cache hits.  Failures are
/// swallowed per-layout — cards fall back to numbered placeholders for
/// any layout we couldn't decode (typically when the user hasn't set
/// `base_game_pak` yet).
///
/// Watched eagerly from [HomePage] so the preload kicks off at app start
/// instead of waiting until the user opens a slot.  Re-watched by
/// [LayoutStylePicker] so its cards rebuild when the PNGs land.
final layoutPreloadProvider =
    FutureProvider<LayoutPreloadResult>((ref) async {
  final config = await ref.watch(configFutureProvider.future);
  final cache = ref.watch(pakCacheProvider);
  return preloadLayoutTextures(cache, config);
});

final texturesProvider = Provider<List<Texture>>((ref) {
  return ref.watch(textureRepositoryProvider).buildTextureList();
});

/// Per-DataTable list of custom slots, sourced from `custom_slots.json`.
/// Reactive: invalidate this provider after edits to refresh the UI.
final customSlotsProvider =
    FutureProvider<Map<String, List<SlotData>>>((ref) async {
  final dir = ref.watch(workingDirProvider);
  return CustomSlotsDataSource(dir).load();
});

/// Per-texture replacement entries, sourced from `replacements.json`.
/// Reactive in the same way as [customSlotsProvider].
final replacementsProvider =
    FutureProvider<Map<String, TextureReplacement>>((ref) async {
  final dir = ref.watch(workingDirProvider);
  return ReplacementsDataSource(dir).load();
});

/// Mutator for `replacements.json`.  Reads the current state, applies a
/// single change, writes the file back, then invalidates [replacementsProvider]
/// so the UI rebuilds from disk (matching the Python tool's "always reread
/// after save" pattern — RR_VHS_Tool.py:5717-5720).
class ReplacementsController {
  final Ref _ref;
  ReplacementsController(this._ref);

  /// Set or replace the user image for [bkgTex].  Always resets the
  /// crop transform to defaults (offset 0/0, zoom 1.0) — picking a new
  /// image starts a fresh full-cover layout, the previous image's
  /// zoom/position is intentionally not carried over.
  ///
  /// Divergence from Python: `_upload` (RR_VHS_Tool.py:12651-12656)
  /// preserves the prior offset/zoom on replace.  We don't — a new image
  /// almost never has the same composition as the one it replaced, so
  /// inheriting the old crop tends to leave subjects half-cropped.  Per
  /// user feedback 2026-05-09.
  Future<void> setImage(String bkgTex, String imagePath) async {
    final dir = _ref.read(workingDirProvider);
    final ds = ReplacementsDataSource(dir);
    final current = await ds.load();
    final next = Map<String, TextureReplacement>.from(current);
    next[bkgTex] = TextureReplacement(
      path: imagePath,
      offsetX: 0,
      offsetY: 0,
      zoom: 1.0,
    );
    await ds.save(next);
    _ref.invalidate(replacementsProvider);
  }

  Future<void> removeImage(String bkgTex) async {
    final dir = _ref.read(workingDirProvider);
    final ds = ReplacementsDataSource(dir);
    final current = await ds.load();
    if (!current.containsKey(bkgTex)) return;
    final next = Map<String, TextureReplacement>.from(current)..remove(bkgTex);
    await ds.save(next);
    _ref.invalidate(replacementsProvider);
  }

  /// Update the (offsetX, offsetY, zoom) crop transform for an existing
  /// replacement. No-op when the slot has no image yet — the cropper UI
  /// only appears after an image is set, so this guard is just defensive.
  Future<void> setTransform(
    String bkgTex, {
    required int offsetX,
    required int offsetY,
    required double zoom,
  }) async {
    final dir = _ref.read(workingDirProvider);
    final ds = ReplacementsDataSource(dir);
    final current = await ds.load();
    final existing = current[bkgTex];
    if (existing == null) return;
    final next = Map<String, TextureReplacement>.from(current);
    next[bkgTex] = TextureReplacement(
      path: existing.path,
      offsetX: offsetX,
      offsetY: offsetY,
      zoom: zoom,
    );
    await ds.save(next);
    _ref.invalidate(replacementsProvider);
  }
}

final replacementsControllerProvider = Provider<ReplacementsController>(
  (ref) => ReplacementsController(ref),
);

/// Mutator for `custom_slots.json`.  Same shape as [ReplacementsController]:
/// load → mutate → save → invalidate.  Edits are scoped per-slot via
/// [updateSlot] (find by globally-unique `bkgTex` and replace in place,
/// preserving genre order).
class SlotsController {
  final Ref _ref;
  SlotsController(this._ref);

  Future<void> updateSlot(SlotData updated) async {
    final dir = _ref.read(workingDirProvider);
    final ds = CustomSlotsDataSource(dir);
    final current = await ds.load();

    final next = <String, List<SlotData>>{};
    var found = false;
    for (final entry in current.entries) {
      next[entry.key] = [
        for (final s in entry.value)
          if (s.bkgTex == updated.bkgTex)
            (() {
              found = true;
              return updated;
            })()
          else
            s,
      ];
    }
    if (!found) return; // unknown slot; nothing to write back

    await ds.save(next);
    _ref.invalidate(customSlotsProvider);
  }

  /// Append a new custom slot to [genre] with the given title + star/rarity
  /// choices. Picks the lowest unused `T_Bkg_<code>_NNN` index, generates a
  /// unique SKU, and assigns the next sequential `T_Sub_NN` (wraps at 99 →
  /// 78). Returns the new slot's `bkgTex`, or `null` when the genre is
  /// unknown / hidden / already at the [kBkgMax] cap.
  Future<String?> addSlot({
    required GenreInfo genre,
    required String title,
    int last2 = 93,
    Rarity rarity = Rarity.common,
  }) async {
    if (kHiddenGenres.contains(genre.name)) return null;

    final dir = _ref.read(workingDirProvider);
    final ds = CustomSlotsDataSource(dir);
    final current = await ds.load();

    final existing =
        current[genre.dataTableName] ?? const <SlotData>[];
    if (existing.length >= kBkgMax) return null;

    final newIdx = nextFreeSlotIndex(
      genre.code,
      existing.map((s) => s.bkgTex),
    );
    final bkgTex = formatCustomBkgTex(genre.code, newIdx);
    final subTex = customSlotSubTex(existing.length + 1);

    // Build the global used-SKU set so generateSku stays unique even
    // across genres (the prefix scan is single-band so collisions across
    // prefixes are unlikely, but cheap to be safe).
    final usedSkus = <int>{};
    for (final list in current.values) {
      for (final s in list) {
        if (s.sku != 0) usedSkus.add(s.sku);
      }
    }

    final sku = generateSku(
      genre: genre.dataTableName,
      slotIndex: newIdx,
      last2: last2,
      rarity: rarity,
      usedSkus: usedSkus,
    );

    final newSlot = SlotData(
      bkgTex: bkgTex,
      pnName: title,
      ls: 0,
      lsc: 4,
      sku: sku,
      subTex: subTex,
    );

    final next = Map<String, List<SlotData>>.from(current);
    next[genre.dataTableName] = [...existing, newSlot];

    await ds.save(next);
    _ref.invalidate(customSlotsProvider);
    return bkgTex;
  }

  /// Delete a custom slot by its globally-unique [bkgTex]. Also drops any
  /// matching entry in `replacements.json` so a stale image path doesn't
  /// outlive the slot. No-op when the slot doesn't exist.
  Future<void> removeSlot(String bkgTex) async {
    final dir = _ref.read(workingDirProvider);
    final slotsDs = CustomSlotsDataSource(dir);
    final current = await slotsDs.load();

    var found = false;
    final next = <String, List<SlotData>>{};
    for (final entry in current.entries) {
      final filtered = [
        for (final s in entry.value)
          if (s.bkgTex == bkgTex)
            (() {
              found = true;
              return null;
            })()
          else
            s,
      ].whereType<SlotData>().toList();
      next[entry.key] = filtered;
    }
    if (!found) return;

    await slotsDs.save(next);

    // Also remove any image replacement so the next add of this same
    // bkgTex (later, with a different movie) doesn't inherit an old
    // cover by accident.
    final replDs = ReplacementsDataSource(dir);
    final replCurrent = await replDs.load();
    if (replCurrent.containsKey(bkgTex)) {
      final replNext = Map<String, TextureReplacement>.from(replCurrent)
        ..remove(bkgTex);
      await replDs.save(replNext);
      _ref.invalidate(replacementsProvider);
    }

    _ref.invalidate(customSlotsProvider);
  }
}

final slotsControllerProvider = Provider<SlotsController>(
  (ref) => SlotsController(ref),
);

/// New Release slots from `nr_custom_slots.json`.  Runs the three load-
/// time migrations Python performs (RR_VHS_Tool.py:2055-2113) and re-
/// persists when any of them mutated the list, so legacy quirks heal
/// at next launch instead of waiting for the user to edit the file:
///
///   1. `applyGenreByteAutoFix` — corrects stale `genre_byte` values
///      from older tool runs (Python Z. 2055-2067).
///   2. `applyDuplicateTexNumRenumber` — renumbers duplicate `tex_num`
///      within a genre (legacy modulo bug from pre-v1.8.2 — Python
///      Z. 2072-2090).
///   3. `applyBkgTex3DigitMigration` — rewrites 2-digit `bkg_tex`
///      values to the v1.8.2 3-digit format (Python Z. 2091-2107).
final nrSlotsProvider = FutureProvider<List<NewReleaseSlot>>((ref) async {
  final dir = ref.watch(workingDirProvider);
  final ds = NrSlotsDataSource(dir);
  final raw = await ds.load();

  final fixed = applyGenreByteAutoFix(raw);
  final renumbered = applyDuplicateTexNumRenumber(fixed.slots);
  final migrated = applyBkgTex3DigitMigration(renumbered.slots);

  if (fixed.fixed > 0 ||
      renumbered.renumbered > 0 ||
      migrated.migrated > 0) {
    await ds.save(migrated.slots);
  }
  return migrated.slots;
});

/// Mutator for `nr_custom_slots.json`.  Same load → mutate → save →
/// invalidate pattern as [SlotsController].  NR slots are uniquely
/// identified by SKU (titles can collide; tex_num + genre may share).
class NrSlotsController {
  final Ref _ref;
  NrSlotsController(this._ref);

  /// Append a new NR slot. Returns the result so the UI can show the
  /// specific reason on failure (unsupported genre, per-genre cap, etc.).
  Future<AddNrResult> addSlot({
    required String genre,
    String title = 'New Release',
    String standeeShape = 'A',
  }) async {
    final dir = _ref.read(workingDirProvider);
    final ds = NrSlotsDataSource(dir);
    final current = await ds.load();
    final result = addNrSlot(
      genre: genre,
      existing: current,
      title: title,
      standeeShape: standeeShape,
    );
    if (!result.isOk) return result;
    final next = [...current, result.slot!];
    await ds.save(next);
    _ref.invalidate(nrSlotsProvider);
    return result;
  }

  /// Remove the slot whose SKU matches [sku]. No-op when the slot doesn't
  /// exist (matches Python's silent fall-through at Z. 2147-2154 when the
  /// index is out of range).  Also clears the slot's selection if it's
  /// currently selected, so the options panel doesn't briefly point at a
  /// vanished record.
  Future<void> removeSlot(int sku) async {
    final dir = _ref.read(workingDirProvider);
    final ds = NrSlotsDataSource(dir);
    final current = await ds.load();
    if (!current.any((s) => s.sku == sku)) return;
    final next = current.where((s) => s.sku != sku).toList();
    await ds.save(next);
    final selected = _ref.read(selectedSlotBkgProvider);
    if (selected == '$kNrSelectionPrefix$sku') {
      _ref.read(selectedSlotBkgProvider.notifier).state = null;
    }
    _ref.invalidate(nrSlotsProvider);
  }

  /// Replace the slot identified by `updated.sku` in place.  No-op when
  /// no slot with that SKU exists.  Used by the options panel for title
  /// edits, standee shape changes, and genre changes.
  Future<void> updateSlot(NewReleaseSlot updated) async {
    final dir = _ref.read(workingDirProvider);
    final ds = NrSlotsDataSource(dir);
    final current = await ds.load();
    var found = false;
    final next = [
      for (final s in current)
        if (s.sku == updated.sku)
          (() {
            found = true;
            return updated;
          })()
        else
          s,
    ];
    if (!found) return;
    await ds.save(next);
    _ref.invalidate(nrSlotsProvider);
  }
}

final nrSlotsControllerProvider = Provider<NrSlotsController>(
  (ref) => NrSlotsController(ref),
);

/// Identifier of the currently selected genre tab.
///
///   * `"All Movies"`   — show every custom slot across all genres.
///   * `"<Genre>"`      — filter to that genre's `dataTableName`
///                        (note: visible name "Kids" → dt "Kid").
///   * `"New Releases"` — reserved for slice 5 (NR support is deferred).
///
/// Default is "All Movies", matching the Python tool's startup tab
/// (RR_VHS_Tool.py:7323).
final selectedTabProvider = StateProvider<String>((_) => 'All Movies');

/// Currently selected slot, identified by either:
///
///   * a genre slot's globally-unique `bkgTex` (e.g. `"T_Bkg_Dra_001"`), or
///   * an NR slot's `nr:<sku>` handle (e.g. `"nr:51234"`).
///
/// NR slots can't reuse `bkgTex` for selection because multiple NRs in the
/// same genre may share one base `T_New_<code>_<NN>` texture (Python
/// design — see RR_VHS_Tool.py:2098-2101).  SKUs are unique across all
/// NRs, so `nr:<sku>` is the smallest stable identifier.
///
/// Null when no slot is picked.  Cleared on tab switch.
final selectedSlotBkgProvider = StateProvider<String?>((_) => null);

/// VHS vs Standee preview mode for the selected NR slot.
/// `false` = VHS cover view (default), `true` = standee shape JPG.
/// Genre slots ignore this (they only have the VHS view).
final standeePreviewModeProvider = StateProvider<bool>((_) => false);

/// Selection-key prefix for NR slots in [selectedSlotBkgProvider].
const String kNrSelectionPrefix = 'nr:';

/// Whether drag-time snapping (centre axes + safe / canvas edges) is
/// active.  Defaults to true — Pythons `_snap_enabled` does the same
/// (RR_VHS_Tool.py:11165).  Toggleable from the cropper editor bar.
final snapEnabledProvider = StateProvider<bool>((_) => true);

/// Whether the layout safe-area overlay (red hatched hidden zones + cyan
/// dashed visible-area border) is drawn on the cropper canvas.  Defaults
/// to `false` to match Pythons `_layout_overlay_var` initial state
/// (RR_VHS_Tool.py:8050).  Toggleable from the LAYOUT OVERLAY pill in the
/// layout section under the cropper.
///
/// Snap targets and centre-axis snap guides are unaffected by this flag —
/// snap stays active and shows guide lines on snap, regardless of overlay
/// visibility.  Python likewise draws snap guides as separate canvas
/// items independent of `_layout_preview` (RR_VHS_Tool.py:11450-11502).
final layoutOverlayProvider = StateProvider<bool>((_) => false);

/// Per-path counter bumped after a file rewrite (e.g. ↻ Rotate).  Mixed
/// into `Image.file` keys for that specific path so the stale cached
/// bytes get replaced — including the `ResizeImage`-wrapped `cacheWidth`
/// variants the simple `FileImage.evict()` call doesn't reach.
///
/// The previous global counter caused every thumbnail in the grid to
/// remount on rotate, which triggered N parallel disk decodes and N
/// dimension re-reads — that's where the "thumbnails go black for 2s"
/// behaviour came from.  Per-path means only the rotated image's widgets
/// remount; everyone else keeps their `_imageInfo` and stays visible.
final coverImageGenerationProvider =
    StateProvider.family<int, String>((ref, path) => 0);

/// Natural pixel dimensions of an image file.  Cached per path; the
/// renderer needs these to position the image at Python-faithful
/// canvas-coords (image at `iw*base*zoom × ih*base*zoom`, placed at
/// `default + offset`) rather than fudging it via cover-fit + scale —
/// which silently breaks at zoom < 1, leaving padding in the visible area.
///
/// Returns null when the file is missing or undecodable; the caller
/// degrades to a placeholder.  Watches the per-path generation counter
/// so a rotate of one cover doesn't invalidate dimension lookups for the
/// other 50 covers in the shelf.
///
/// **Not** autoDispose: thumbnails outside the GridView's cacheExtent get
/// unmounted and would otherwise re-read dims from disk every time the
/// user scrolls back to them.  Each entry is two ints (~40 bytes) so the
/// session-long cost of pinning all of them is negligible.
final imageDimensionsProvider =
    FutureProvider.family<({int w, int h})?, String>((ref, path) async {
  ref.watch(coverImageGenerationProvider(path));
  final result = await readImageDimensions(path);
  if (result == null) return null;
  return (w: result.width, h: result.height);
});

class BuildState {
  final bool isRunning;
  final List<String> log;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int? lastPakSizeBytes;
  final String? lastInstalledPath;
  /// Wall-clock time of the most recent build attempt (success or failure),
  /// or null if no build has run yet.  Used by the UI to show "built in
  /// X.Ys" alongside the success banner.
  final int? lastBuildElapsedMs;
  /// Live progress while [isRunning] is true.  null when idle.
  final BuildProgress? progress;

  const BuildState({
    this.isRunning = false,
    this.log = const [],
    this.lastErrorCode,
    this.lastErrorMessage,
    this.lastPakSizeBytes,
    this.lastInstalledPath,
    this.lastBuildElapsedMs,
    this.progress,
  });

  /// Most recent build was a clean success (the pak was built and we have
  /// no error).  install path being null is fine here — it just means the
  /// user hasn't configured `mods_folder`.
  bool get lastBuildSucceeded =>
      lastErrorCode == null && lastPakSizeBytes != null;

  BuildState copyWith({
    bool? isRunning,
    List<String>? log,
    String? lastErrorCode,
    String? lastErrorMessage,
    int? lastPakSizeBytes,
    String? lastInstalledPath,
    int? lastBuildElapsedMs,
    BuildProgress? progress,
    bool clearProgress = false,
  }) {
    return BuildState(
      isRunning: isRunning ?? this.isRunning,
      log: log ?? this.log,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      lastPakSizeBytes: lastPakSizeBytes ?? this.lastPakSizeBytes,
      lastInstalledPath: lastInstalledPath ?? this.lastInstalledPath,
      lastBuildElapsedMs: lastBuildElapsedMs ?? this.lastBuildElapsedMs,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }
}

class BuildController extends StateNotifier<BuildState> {
  final Ref _ref;
  IOSink? _logSink;
  final List<String> _pendingLog = [];
  Timer? _flushTimer;

  BuildController(this._ref) : super(const BuildState()) {
    final builder = _ref.read(pakBuilderProvider);
    builder.logStream.listen((line) {
      // Sink the line synchronously so build_last.log is always complete
      // even if the UI batches.  But coalesce UI state updates: a build
      // emits ~100-300 log lines, and rebuilding the ListView per-line
      // (with O(n) list cloning) makes the panel stutter and the spinner
      // freeze.  Flush pending lines into state every 100 ms.
      _pendingLog.add(line);
      _logSink?.writeln(line);
      _flushTimer ??=
          Timer(const Duration(milliseconds: 100), _flushPendingLog);
    });
    builder.progressStream.listen((p) {
      state = state.copyWith(progress: p);
    });
  }

  void _flushPendingLog() {
    _flushTimer = null;
    if (_pendingLog.isEmpty) return;
    state = state.copyWith(log: [...state.log, ..._pendingLog]);
    _pendingLog.clear();
  }

  /// Persistent path of the most recent build log.  Truncated on each `ship()`
  /// call.  Lives next to `config.json` so it's easy to find and share when
  /// debugging an unexpected build outcome.
  String get logFilePath =>
      p.join(_ref.read(workingDirProvider), 'build_last.log');

  Future<void> ship() async {
    if (state.isRunning) return;
    state = const BuildState(isRunning: true, log: []);

    // Truncate + open append-mode sink so log lines persist even if a later
    // step crashes the isolate.
    await _logSink?.close();
    final logFile = File(logFilePath);
    try {
      await logFile.writeAsString(''); // truncate
      _logSink = logFile.openWrite(mode: FileMode.append);
    } catch (_) {
      _logSink = null; // best-effort; the in-memory log still works
    }

    final sw = Stopwatch()..start();
    try {
      final config = await _ref.read(configRepositoryProvider).load();
      final result = await _ref.read(pakBuilderProvider).build(config);
      sw.stop();

      // Flush any pending log batches synchronously so the build
      // summary table shows up immediately when the spinner stops.
      _flushTimer?.cancel();
      _flushTimer = null;
      _flushPendingLog();

      state = state.copyWith(
        isRunning: false,
        lastErrorCode: result.errorCode,
        lastErrorMessage: result.errorMessage,
        lastPakSizeBytes: result.pakSizeBytes,
        lastInstalledPath: result.installedPath,
        lastBuildElapsedMs: sw.elapsedMilliseconds,
        clearProgress: true,
      );
    } finally {
      await _logSink?.flush();
      await _logSink?.close();
      _logSink = null;
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}

final buildControllerProvider =
    StateNotifierProvider<BuildController, BuildState>((ref) {
  return BuildController(ref);
});
