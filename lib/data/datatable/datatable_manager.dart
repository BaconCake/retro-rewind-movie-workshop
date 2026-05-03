import '../../core/constants/genres.dart';
import '../../domain/entities/app_config.dart';
import 'datatable_builder.dart';
import 'slot_data.dart';

/// Orchestrates DataTable rebuilding across all 13 genres. Mirrors Python's
/// `DataTableManager.get_modified_datatables` (RR_VHS_Tool.py:4737-5095) at
/// the slice 2c-D scope: every genre is rebuilt from its base-game template
/// (decoded slots + optional title overrides) and the resulting uasset+uexp
/// pairs are returned for PakBuilder to write.
class DataTableManager {
  final DataTableBuilder builder;

  DataTableManager(this.builder);

  /// Build all genres. Returns `{dataTableName: result}`. Per-genre failure
  /// throws — callers either succeed for all 13 or fail loudly. Adventure
  /// is included; the project memory notes it's unused in-game but still
  /// needs to parse cleanly (the parser already handles its zero-tail uexp).
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
}
