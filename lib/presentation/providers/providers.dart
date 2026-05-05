import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../data/datasources/custom_slots_data_source.dart';
import '../../data/datasources/json_file_data_source.dart';
import '../../data/datasources/replacements_data_source.dart';
import '../../data/datatable/slot_data.dart';
import '../../data/repositories/config_repository_impl.dart';
import '../../data/repositories/pak_builder_impl.dart';
import '../../data/repositories/texture_repository_impl.dart';
import '../../data/services/cover_actions.dart';
import '../../domain/custom_slot_naming.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/texture.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/repositories/config_repository.dart';
import '../../domain/repositories/pak_builder.dart';
import '../../domain/repositories/texture_repository.dart';
import '../../domain/sku.dart';

/// The directory the app treats as its working dir. We prefer the current
/// working directory if it contains config.json — this is what `flutter run`
/// gives us (project root), and it's also what the user gets when they
/// launch a built .exe from its own folder. Otherwise we fall back to the
/// directory containing the executable, matching the Python tool.
final workingDirProvider = Provider<String>((ref) {
  final cwd = Directory.current.path;
  if (File(p.join(cwd, 'config.json')).existsSync()) return cwd;

  final exe = Platform.resolvedExecutable;
  if (exe.contains('flutter_tester') || exe.endsWith('dart.exe')) {
    return cwd;
  }
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

  Future<void> setImage(String bkgTex, String imagePath) async {
    final dir = _ref.read(workingDirProvider);
    final ds = ReplacementsDataSource(dir);
    final current = await ds.load();
    final next = Map<String, TextureReplacement>.from(current);
    final existing = next[bkgTex];
    next[bkgTex] = TextureReplacement(
      path: imagePath,
      offsetX: existing?.offsetX ?? 0,
      offsetY: existing?.offsetY ?? 0,
      zoom: existing?.zoom ?? 1.0,
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

/// Currently selected slot, identified by its globally-unique `bkgTex`
/// (e.g. `"T_Bkg_Dra_001"`).  Null when no slot is picked.  Drives the
/// preview + slot-options panels.
final selectedSlotBkgProvider = StateProvider<String?>((_) => null);

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

  const BuildState({
    this.isRunning = false,
    this.log = const [],
    this.lastErrorCode,
    this.lastErrorMessage,
    this.lastPakSizeBytes,
    this.lastInstalledPath,
  });

  BuildState copyWith({
    bool? isRunning,
    List<String>? log,
    String? lastErrorCode,
    String? lastErrorMessage,
    int? lastPakSizeBytes,
    String? lastInstalledPath,
  }) {
    return BuildState(
      isRunning: isRunning ?? this.isRunning,
      log: log ?? this.log,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      lastPakSizeBytes: lastPakSizeBytes ?? this.lastPakSizeBytes,
      lastInstalledPath: lastInstalledPath ?? this.lastInstalledPath,
    );
  }
}

class BuildController extends StateNotifier<BuildState> {
  final Ref _ref;
  IOSink? _logSink;

  BuildController(this._ref) : super(const BuildState()) {
    _ref.read(pakBuilderProvider).logStream.listen((line) {
      state = state.copyWith(log: [...state.log, line]);
      _logSink?.writeln(line);
    });
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

    try {
      final config = await _ref.read(configRepositoryProvider).load();
      final result = await _ref.read(pakBuilderProvider).build(config);

      state = state.copyWith(
        isRunning: false,
        lastErrorCode: result.errorCode,
        lastErrorMessage: result.errorMessage,
        lastPakSizeBytes: result.pakSizeBytes,
        lastInstalledPath: result.installedPath,
      );
    } finally {
      await _logSink?.flush();
      await _logSink?.close();
      _logSink = null;
    }
  }
}

final buildControllerProvider =
    StateNotifierProvider<BuildController, BuildState>((ref) {
  return BuildController(ref);
});
