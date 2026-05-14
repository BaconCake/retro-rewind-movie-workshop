import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../data/datasources/custom_slots_data_source.dart';
import '../../data/datasources/json_file_data_source.dart';
import '../../data/datasources/nr_slots_data_source.dart';
import '../../data/datasources/replacements_data_source.dart';
import '../../data/datasources/sort_prefs_data_source.dart';
import '../../data/datasources/tracking_set_data_source.dart';
import '../../data/datatable/slot_data.dart';
import '../../data/repositories/config_repository_impl.dart';
import '../../data/repositories/pak_builder_impl.dart';
import '../../data/repositories/texture_repository_impl.dart';
import '../../data/services/cover_actions.dart';
import '../../data/services/layout_overlay_loader.dart';
import '../../data/services/layout_preloader.dart';
import '../../data/services/pak_cache.dart';
import '../../domain/custom_slot_naming.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/new_release_slot.dart';
import '../../domain/entities/texture.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/nr_slot_logic.dart';
import '../../domain/replacements_migration.dart';
import '../../domain/sort.dart';
import '../../domain/timestamps.dart';
import '../../domain/tracking.dart';
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

/// Alpha-masked `ui.Image` of `T_Layout_NN_bc_full.png` for layout `n`.
/// Lazy + per-layout cached.  Powers the "Layout Overlay" toggle on the
/// cropper canvas (RR_VHS_Tool.py:12805-12884).  Returns `null` when the
/// texture is unavailable — callers degrade to hatch + dashed border.
final layoutOverlayImageProvider =
    FutureProvider.family<ui.Image?, int>((ref, n) async {
  final config = await ref.watch(configFutureProvider.future);
  final cache = ref.watch(pakCacheProvider);
  return loadLayoutOverlayImage(cache, config, n);
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
///
/// Runs the legacy-key migration on load (Python parity with
/// `load_replacements` at RR_VHS_Tool.py:3022-3038): legacy 2-digit
/// `T_Bkg_<code>_NN` and `T_New_<code>_NN` keys are rewritten to the
/// v1.8.2 3-digit form and the file is re-persisted when anything
/// changed.  Closes the gap left by slice 2a.5 which migrated
/// `nr_custom_slots.json` but not `replacements.json`.
final replacementsProvider =
    FutureProvider<Map<String, TextureReplacement>>((ref) async {
  final dir = ref.watch(workingDirProvider);
  final ds = ReplacementsDataSource(dir);
  final raw = await ds.load();
  final migrated = applyReplacementsKeyMigration(raw);
  if (migrated.migrated > 0) {
    await ds.save(migrated.entries);
  }
  return migrated.entries;
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
    await _ref.read(trackingProvider.notifier).markEditedForBkgTex(bkgTex);
    // Fire both controllers — each is a no-op when bkgTex doesn't match
    // its slot type, so the caller doesn't need to dispatch.
    await _ref.read(slotsControllerProvider).touchEditTime(bkgTex);
    await _ref.read(nrSlotsControllerProvider).touchEditTime(bkgTex);
  }

  Future<void> removeImage(String bkgTex) async {
    final dir = _ref.read(workingDirProvider);
    final ds = ReplacementsDataSource(dir);
    final current = await ds.load();
    if (!current.containsKey(bkgTex)) return;
    final next = Map<String, TextureReplacement>.from(current)..remove(bkgTex);
    await ds.save(next);
    _ref.invalidate(replacementsProvider);
    await _ref.read(trackingProvider.notifier).markEditedForBkgTex(bkgTex);
    // Fire both controllers — each is a no-op when bkgTex doesn't match
    // its slot type, so the caller doesn't need to dispatch.
    await _ref.read(slotsControllerProvider).touchEditTime(bkgTex);
    await _ref.read(nrSlotsControllerProvider).touchEditTime(bkgTex);
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
    await _ref.read(trackingProvider.notifier).markEditedForBkgTex(bkgTex);
    // Fire both controllers — each is a no-op when bkgTex doesn't match
    // its slot type, so the caller doesn't need to dispatch.
    await _ref.read(slotsControllerProvider).touchEditTime(bkgTex);
    await _ref.read(nrSlotsControllerProvider).touchEditTime(bkgTex);
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

    // Bump lastEditedAt unconditionally — every call to updateSlot
    // represents a user-driven edit (title change, star/rarity regen,
    // layout pick).  Preserves whatever createdAt was already on the
    // slot (copyWith only overwrites the named field).
    final touched = updated.copyWith(lastEditedAt: nowIso());

    final next = <String, List<SlotData>>{};
    var found = false;
    for (final entry in current.entries) {
      next[entry.key] = [
        for (final s in entry.value)
          if (s.bkgTex == touched.bkgTex)
            (() {
              found = true;
              return touched;
            })()
          else
            s,
      ];
    }
    if (!found) return; // unknown slot; nothing to write back

    await ds.save(next);
    _ref.invalidate(customSlotsProvider);
    await _ref
        .read(trackingProvider.notifier)
        .markEdited(genreSlotKey(touched));
  }

  /// Stamp `lastEditedAt = now` on the slot identified by [bkgTex].
  /// No-op when [bkgTex] doesn't match any genre slot — that lets
  /// `ReplacementsController` call this for both genre and NR
  /// bkgTexes; NR-side timestamps would need a separate path on the
  /// NR controller, but they aren't surfaced here.
  ///
  /// Does NOT touch tracking or invalidate replacementsProvider — the
  /// caller (ReplacementsController) handles both.  Invalidates
  /// customSlotsProvider so the shelf re-sorts immediately.
  Future<void> touchEditTime(String bkgTex) async {
    final dir = _ref.read(workingDirProvider);
    final ds = CustomSlotsDataSource(dir);
    final current = await ds.load();
    final ts = nowIso();
    var found = false;
    final next = <String, List<SlotData>>{};
    for (final entry in current.entries) {
      next[entry.key] = [
        for (final s in entry.value)
          if (s.bkgTex == bkgTex)
            (() {
              found = true;
              return s.copyWith(lastEditedAt: ts);
            })()
          else
            s,
      ];
    }
    if (!found) return;
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
      createdAt: nowIso(),
    );

    final next = Map<String, List<SlotData>>.from(current);
    next[genre.dataTableName] = [...existing, newSlot];

    await ds.save(next);
    _ref.invalidate(customSlotsProvider);
    // A brand-new slot has by definition not been shipped yet, so it
    // shows the "Edited since last build" badge until the next build.
    await _ref.read(trackingProvider.notifier).markEdited(bkgTex);
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
    // Change 3: drop this slot from both tracking sets so a deleted-
    // then-rebuilt slot doesn't appear shipped against a key that no
    // longer exists.  Python parity at RR_VHS_Tool.py:10767-10773.
    await _ref.read(trackingProvider.notifier).removeKey(bkgTex);
  }
}

final slotsControllerProvider = Provider<SlotsController>(
  (ref) => SlotsController(ref),
);

/// Wipe the entire custom library in one shot: clears `custom_slots.json`,
/// `nr_custom_slots.json`, `replacements.json` and both tracking sets, then
/// clears the active selection.  Bulk-write rather than per-slot loop —
/// matches Python's `_clear_all_custom` (RR_VHS_Tool.py:10814-10847) and
/// keeps the operation fast for large libraries.
class ClearAllController {
  final Ref _ref;
  ClearAllController(this._ref);

  /// Returns the count actually removed (genre + NR), so the caller can
  /// show a "Removed N movies" toast.  Zero when the library was already
  /// empty (and no files touched).
  Future<int> call() async {
    final dir = _ref.read(workingDirProvider);

    final slotsDs = CustomSlotsDataSource(dir);
    final nrDs = NrSlotsDataSource(dir);
    final replDs = ReplacementsDataSource(dir);

    final genreCurrent = await slotsDs.load();
    final nrCurrent = await nrDs.load();
    final genreCount =
        genreCurrent.values.fold<int>(0, (acc, list) => acc + list.length);
    final nrCount = nrCurrent.length;
    if (genreCount == 0 && nrCount == 0) return 0;

    await slotsDs.save(const <String, List<SlotData>>{});
    await nrDs.save(const <NewReleaseSlot>[]);
    await replDs.save(const <String, TextureReplacement>{});

    // Reset tracking (both sets), then clear the active selection so the
    // right rail doesn't briefly point at a vanished slot.
    await _ref.read(trackingProvider.notifier).clearAll();
    _ref.read(selectedSlotBkgProvider.notifier).state = null;

    // Wipe the clipboard-paste staging directory.  Every PNG in here was
    // written for a slot that no longer exists, so leaving them on disk
    // is pure litter (and the directory only grows over time — there's
    // no per-paste cleanup).  Best-effort: a permission failure or
    // already-missing directory must not abort the rest of the clear.
    try {
      final pastedDir = Directory(p.join(dir, '.pasted_covers'));
      if (await pastedDir.exists()) {
        await pastedDir.delete(recursive: true);
      }
    } catch (_) {
      // Next paste will recreate the directory; non-fatal.
    }

    _ref.invalidate(customSlotsProvider);
    _ref.invalidate(nrSlotsProvider);
    _ref.invalidate(replacementsProvider);

    return genreCount + nrCount;
  }
}

final clearAllControllerProvider =
    Provider<ClearAllController>((ref) => ClearAllController(ref));

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

const _kEditedSlotsFile = 'edited_slots.json';
const _kShippedSlotsFile = 'shipped_slots.json';

/// Immutable snapshot of both build-status tracking sets.  Owned by
/// [TrackingNotifier]; widgets watch [trackingProvider] and read
/// `state.edited` / `state.shipped` directly.
///
/// The shape is a value object rather than two separate AsyncValues
/// because tracking is small (<1k strings total), fully in-memory, and
/// mutated frequently (every edit).  Holding it as a sync state makes
/// mutations instant — no AsyncLoading flicker on OTHER cards while one
/// card is being marked edited.
@immutable
class TrackingState {
  final Set<String> edited;
  final Set<String> shipped;
  const TrackingState({
    this.edited = const <String>{},
    this.shipped = const <String>{},
  });
}

/// In-memory tracking with async disk persistence.  Loads both files
/// on construction; mutations apply synchronously to state and fire-
/// and-forget the disk write.
///
/// Lifecycle:
///   1. Construct → emit empty `TrackingState`.
///   2. `_init` reads `edited_slots.json` + `shipped_slots.json` and
///      emits the loaded sets — happens within the first frame for a
///      reasonably-sized library (the files are sorted JSON arrays).
///   3. `_healOrphans` waits for slot providers, prunes stale keys,
///      and re-emits + persists if anything was dropped.  Python parity
///      with `_prune_orphan_tracking` (RR_VHS_Tool.py:7726-7759).
///
/// Mutators ([markEdited] / [markEditedForBkgTex] / [removeKey] /
/// [onBuildSuccess]) emit a new state synchronously, then persist in
/// the background.  No invalidate calls — widgets see the new state on
/// the very next frame, with no intermediate "loading" pass.
class TrackingNotifier extends StateNotifier<TrackingState> {
  final Ref _ref;
  TrackingNotifier(this._ref) : super(const TrackingState()) {
    _init();
  }

  TrackingSetDataSource _editedDs() => TrackingSetDataSource(
        workingDir: _ref.read(workingDirProvider),
        fileName: _kEditedSlotsFile,
      );
  TrackingSetDataSource _shippedDs() => TrackingSetDataSource(
        workingDir: _ref.read(workingDirProvider),
        fileName: _kShippedSlotsFile,
      );

  Future<void> _init() async {
    final edited = await _editedDs().load();
    if (!mounted) return;
    final shipped = await _shippedDs().load();
    if (!mounted) return;
    state = TrackingState(edited: edited, shipped: shipped);
    await _healOrphans();
  }

  Future<void> _healOrphans() async {
    try {
      final genreSlots = await _ref.read(customSlotsProvider.future);
      final nrs = await _ref.read(nrSlotsProvider.future);
      if (!mounted) return;
      final valid =
          validTrackingKeys(genreSlotsByGenre: genreSlots, nrs: nrs);
      final eR = pruneOrphans(state.edited, valid);
      final sR = pruneOrphans(state.shipped, valid);
      if (eR.dropped.isEmpty && sR.dropped.isEmpty) return;
      state = TrackingState(edited: eR.pruned, shipped: sR.pruned);
      if (eR.dropped.isNotEmpty) {
        if (eR.pruned.isEmpty) {
          await _editedDs().delete();
        } else {
          await _editedDs().save(eR.pruned);
        }
      }
      if (sR.dropped.isNotEmpty) await _shippedDs().save(sR.pruned);
    } catch (_) {
      // Tracking heal is non-fatal — if slot providers error out
      // (corrupt JSON, etc.) we keep the pre-heal state so the user
      // still sees their badges and can ship to recover.
    }
  }

  Future<void> markEdited(String key) async {
    if (state.edited.contains(key)) return;
    final next = <String>{...state.edited, key};
    state = TrackingState(edited: next, shipped: state.shipped);
    await _editedDs().save(next);
  }

  /// Same as [markEdited] but takes a texture-name (bkgTex) and resolves
  /// it to the right stable key:
  ///
  ///   * `T_Bkg_*` → bkgTex verbatim (genre slot key is bkgTex anyway).
  ///   * `T_New_*` → look up the NR slot's SKU so the entry survives the
  ///     user later changing the NR's genre (bkgTex flips Drama → Horror
  ///     but SKU is invariant).  Falls back to bkgTex when no NR matches
  ///     — keeps the badge visible until the orphan pruner reconciles.
  Future<void> markEditedForBkgTex(String bkgTex) async {
    if (bkgTex.startsWith('T_New_')) {
      final nrs = await _ref.read(nrSlotsProvider.future);
      for (final n in nrs) {
        if (n.bkgTex == bkgTex) {
          await markEdited(nrSlotKey(n));
          return;
        }
      }
    }
    await markEdited(bkgTex);
  }

  Future<void> removeKey(String key) async {
    final hadEdit = state.edited.contains(key);
    final hadShip = state.shipped.contains(key);
    if (!hadEdit && !hadShip) return;
    final newEdited =
        hadEdit ? (<String>{...state.edited}..remove(key)) : state.edited;
    final newShipped =
        hadShip ? (<String>{...state.shipped}..remove(key)) : state.shipped;
    state = TrackingState(edited: newEdited, shipped: newShipped);
    if (hadEdit) {
      if (newEdited.isEmpty) {
        await _editedDs().delete();
      } else {
        await _editedDs().save(newEdited);
      }
    }
    if (hadShip) await _shippedDs().save(newShipped);
  }

  Future<void> onBuildSuccess(Set<String> currentKeys) async {
    state = TrackingState(edited: const <String>{}, shipped: currentKeys);
    await _editedDs().delete();
    await _shippedDs().save(currentKeys);
  }

  /// Drop both tracking sets — used by the bulk-delete flow.  Python parity
  /// at RR_VHS_Tool.py:10830-10833: a fresh slot created after clear-all
  /// reuses the smallest-free tex_num (likely 001 again), and would
  /// otherwise inherit a stale "shipped" badge from the prior occupant.
  Future<void> clearAll() async {
    if (state.edited.isEmpty && state.shipped.isEmpty) return;
    state = const TrackingState();
    await _editedDs().delete();
    await _shippedDs().delete();
  }
}

final trackingProvider =
    StateNotifierProvider<TrackingNotifier, TrackingState>(
        (ref) => TrackingNotifier(ref));

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
    final newSlot = result.slot!;
    final next = [...current, newSlot];
    await ds.save(next);
    _ref.invalidate(nrSlotsProvider);
    // New NR slots show the "Edited" badge until the next build.
    await _ref
        .read(trackingProvider.notifier)
        .markEdited(nrSlotKey(newSlot));
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
    // Change 3: drop this NR's tracking from both edited and shipped so
    // a re-created NR doesn't inherit the deleted one's badge state.
    // Python parity at RR_VHS_Tool.py:9897-9908.
    await _ref.read(trackingProvider.notifier).removeKey('NR_$sku');
  }

  /// Replace the slot identified by `updated.sku` in place.  No-op when
  /// no slot with that SKU exists.  Used by the options panel for title
  /// edits, standee shape changes, and genre changes.  Always bumps
  /// `lastEditedAt` — Python parity with `_flush_pending_nr_timestamp`
  /// (RR_VHS_Tool.py:7826-7845).
  Future<void> updateSlot(NewReleaseSlot updated) async {
    final dir = _ref.read(workingDirProvider);
    final ds = NrSlotsDataSource(dir);
    final current = await ds.load();
    final touched = updated.copyWith(lastEditedAt: nowIso());
    var found = false;
    final next = [
      for (final s in current)
        if (s.sku == touched.sku)
          (() {
            found = true;
            return touched;
          })()
        else
          s,
    ];
    if (!found) return;
    await ds.save(next);
    _ref.invalidate(nrSlotsProvider);
    await _ref
        .read(trackingProvider.notifier)
        .markEdited(nrSlotKey(touched));
  }

  /// Stamp `lastEditedAt = now` on the NR slot whose `bkgTex` matches.
  /// Symmetric counterpart to `SlotsController.touchEditTime` — called
  /// by `ReplacementsController` so cover-image edits to an NR also
  /// register as editing the slot.
  ///
  /// No-op when [bkgTex] doesn't match any NR; that lets the caller
  /// fire both controllers' `touchEditTime` calls blindly without
  /// dispatching by `bkgTex` prefix.
  Future<void> touchEditTime(String bkgTex) async {
    final dir = _ref.read(workingDirProvider);
    final ds = NrSlotsDataSource(dir);
    final current = await ds.load();
    final ts = nowIso();
    var found = false;
    final next = [
      for (final s in current)
        if (s.bkgTex == bkgTex)
          (() {
            found = true;
            return s.copyWith(lastEditedAt: ts);
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

/// Per-tab sort preference map.  Same StateNotifier pattern as
/// [trackingProvider] so a tab switch / sort selection updates the
/// shelf synchronously — no AsyncValue flicker.  Persists every change
/// to `sort_preferences.json` in the working dir.  Python parity:
/// `_sort_prefs` (RR_VHS_Tool.py:7454) + `_on_sort_selected`
/// (Z. 11106-11118).
///
/// `"All Movies"` is intentionally never keyed — the shelf hides the
/// dropdown on that tab (briefing §5.4).  NR tab uses the literal key
/// `"New Releases"` to match Python.
class SortPrefsNotifier extends StateNotifier<Map<String, String>> {
  final Ref _ref;
  SortPrefsNotifier(this._ref) : super(const <String, String>{}) {
    _load();
  }

  SortPrefsDataSource _ds() =>
      SortPrefsDataSource(_ref.read(workingDirProvider));

  Future<void> _load() async {
    final loaded = await _ds().load();
    if (!mounted) return;
    state = loaded;
  }

  /// Returns the sort key for [tabName], falling back to
  /// [kDefaultSortKey] when the tab has no saved preference yet.
  SortKey getForTab(String tabName) =>
      SortKey.fromWireKey(state[tabName]);

  Future<void> setForTab(String tabName, SortKey key) async {
    if (state[tabName] == key.wireKey) return;
    final next = <String, String>{...state, tabName: key.wireKey};
    state = next;
    await _ds().save(next);
  }
}

final sortPrefsProvider =
    StateNotifierProvider<SortPrefsNotifier, Map<String, String>>(
        (ref) => SortPrefsNotifier(ref));

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

      // On a successful install: clear "edited" (this build shipped every
      // pending change) and replace "shipped" with the current slot set
      // (so any slots deleted since the last build vanish from the badge).
      // Python parity at RR_VHS_Tool.py:14878-14888.
      if (result.errorCode == null &&
          result.installedPath != null &&
          result.installedPath!.isNotEmpty) {
        try {
          final genreSlots =
              await _ref.read(customSlotsProvider.future);
          final nrs = await _ref.read(nrSlotsProvider.future);
          final currentKeys = validTrackingKeys(
              genreSlotsByGenre: genreSlots, nrs: nrs);
          await _ref
              .read(trackingProvider.notifier)
              .onBuildSuccess(currentKeys);
        } catch (_) {
          // Tracking is non-fatal — a snapshot failure must not erase
          // the user's just-completed build outcome from the UI.
        }
      }
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
