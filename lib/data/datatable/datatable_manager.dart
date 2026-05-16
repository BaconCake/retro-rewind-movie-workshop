import '../../core/constants/genres.dart';
import '../../domain/entities/app_config.dart';
import 'datatable_builder.dart';
import 'slot_data.dart';

/// Outcome of [DataTableManager.buildAllLenient]: per-genre results split
/// into successes and failures so the build pipeline can ship a partial
/// pak (Python's behaviour — RR_VHS_Tool.py:14722-14740).
class DataTableBuildOutcome {
  /// Successful builds, keyed by DataTable name.
  final Map<String, DataTableBuildResult> built;

  /// Failures, keyed by DataTable name.  Always [DataTableBuildError]; any
  /// unexpected throw is wrapped with code `E004` to match Python's
  /// `except Exception` fallback.
  final Map<String, DataTableBuildError> failed;

  const DataTableBuildOutcome({required this.built, required this.failed});

  bool get allSuccess => failed.isEmpty;
}

/// Orchestrates DataTable rebuilding across all 13 genres. Mirrors Python's
/// `DataTableManager.get_modified_datatables` (RR_VHS_Tool.py:4737-5095) at
/// the slice 2c-D scope: every genre is rebuilt from its base-game template
/// (decoded slots + optional title overrides) and the resulting uasset+uexp
/// pairs are returned for PakBuilder to write.
class DataTableManager {
  final DataTableBuilder builder;

  DataTableManager(this.builder);

  /// Build all genres.  Returns `{dataTableName: result}`.  Per-genre
  /// failure throws — kept for tests and callers that want all-or-nothing.
  /// Production builds use [buildAllLenient] so a single bad genre doesn't
  /// kill the whole pak.
  ///
  /// [slotOverrides] / [titleOverridesByGenre] are keyed by `dataTableName`
  /// (the asset-side identifier — "Kid" not "Kids", "Sci-Fi" not "SciFi").
  /// Missing keys mean "use base-game slots / no overrides".
  Future<Map<String, DataTableBuildResult>> buildAll(
    AppConfig config, {
    Map<String, List<SlotData>>? slotOverrides,
    Map<String, Map<String, String>>? titleOverridesByGenre,
    Map<String, Map<int, String>>? bkgTexPatchesByDt,
    void Function(String dtName, String message)? log,
  }) async {
    final out = <String, DataTableBuildResult>{};
    for (final g in kGenres) {
      final dt = g.dataTableName;
      // CUSTOM_ONLY_MODE: only rebuild DataTables for genres that have
      // explicit slot overrides.  Genres without overrides are intentionally
      // omitted from the mod pak so the engine falls through to the base
      // game's DataTable (showing the original movies untouched).  Mirrors
      // Python's `save_datatable` when `CUSTOM_ONLY_MODE = True`
      // (RR_VHS_Tool.py:5040-5045).
      final overrides = slotOverrides?[dt];
      if (overrides == null || overrides.isEmpty) continue;
      log?.call(dt, 'building...');
      final result = await builder.build(
        config,
        dt,
        slotOverride: overrides,
        titleOverrides: titleOverridesByGenre?[dt] ?? const {},
        bkgTexPatches: bkgTexPatchesByDt?[dt] ?? const {},
      );
      out[dt] = result;
      log?.call(dt,
          'ok (${result.slotCount} slots, '
          '${result.uassetBytes.length}+${result.uexpBytes.length} bytes)');
    }
    return out;
  }

  /// Lenient variant of [buildAll]: per-genre failures are caught, logged,
  /// and reported in the returned [DataTableBuildOutcome] instead of
  /// aborting.  Pure port of Python's per-DataTable loop
  /// (RR_VHS_Tool.py:14722-14740), which accumulates `[E004]`/`[E015]`
  /// errors and ships a partial pak with a warning summary.
  ///
  /// The build pipeline should prefer this over [buildAll] so a single
  /// broken genre still lets the user ship their other 12.
  Future<DataTableBuildOutcome> buildAllLenient(
    AppConfig config, {
    Map<String, List<SlotData>>? slotOverrides,
    Map<String, Map<String, String>>? titleOverridesByGenre,
    Map<String, Map<int, String>>? bkgTexPatchesByDt,
    void Function(String dtName, String message)? log,
  }) async {
    final built = <String, DataTableBuildResult>{};
    final failed = <String, DataTableBuildError>{};
    for (final g in kGenres) {
      final dt = g.dataTableName;
      final overrides = slotOverrides?[dt];
      if (overrides == null || overrides.isEmpty) continue;
      log?.call(dt, 'building...');
      try {
        final result = await builder.build(
          config,
          dt,
          slotOverride: overrides,
          titleOverrides: titleOverridesByGenre?[dt] ?? const {},
          bkgTexPatches: bkgTexPatchesByDt?[dt] ?? const {},
        );
        built[dt] = result;
        log?.call(dt,
            'ok (${result.slotCount} slots, '
            '${result.uassetBytes.length}+${result.uexpBytes.length} bytes)');
      } on DataTableBuildError catch (e) {
        failed[dt] = e;
        log?.call(dt, 'FAILED [${e.code}]: ${e.message}');
      } catch (e) {
        // Python's `except Exception as e: errors.append(f"[E004] ...")`
        // (RR_VHS_Tool.py:14737-14739).
        failed[dt] = DataTableBuildError('E004', dt, e.toString());
        log?.call(dt, 'THREW: $e');
      }
    }
    return DataTableBuildOutcome(built: built, failed: failed);
  }
}
