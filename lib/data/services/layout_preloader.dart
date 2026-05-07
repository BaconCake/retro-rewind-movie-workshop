import '../../domain/entities/app_config.dart';
import 'pak_cache.dart';

/// Result of a single layout's preload — surface-level enough that the
/// UI can flag config / pak issues without digging through warnings.
class LayoutPreloadEntry {
  final int n;
  final bool ok;
  final String? warning;
  const LayoutPreloadEntry({required this.n, required this.ok, this.warning});
}

/// Outcome of a [preloadLayoutTextures] run.
class LayoutPreloadResult {
  final List<LayoutPreloadEntry> entries;
  const LayoutPreloadResult(this.entries);

  bool get allOk => entries.every((e) => e.ok);
  Iterable<LayoutPreloadEntry> get failures => entries.where((e) => !e.ok);
}

/// Decode + cache the 5 base-game layout textures so [LayoutStylePicker]'s
/// thumbnail cards have real artwork to render.  Pure port of
/// `_start_layout_preload` (RR_VHS_Tool.py:7202-7241): for each n ∈ 1..5,
/// extracts the ubulk via [PakCache], decodes the DXT1 mip0, and writes
/// `T_Layout_NN_bc.png` (1024×2048, T_Bkg-aligned) plus
/// `T_Layout_NN_bc_full.png` (2048×2048, uncropped) to
/// `<workingDir>/layout_cache/`.
///
/// On cache hits (PNG already on disk) the call is essentially free —
/// the user pays the decode cost exactly once per cache wipe.
///
/// Failures (missing pak, invalid config, decode error) are swallowed
/// per-layout into [LayoutPreloadEntry.warning] rather than thrown — the
/// UI degrades to numbered placeholder thumbnails for the failed layouts
/// and stays usable.
///
/// [onProgress] fires after each layout completes with `(done, total)`.
Future<LayoutPreloadResult> preloadLayoutTextures(
  PakCache cache,
  AppConfig config, {
  void Function(int done, int total)? onProgress,
}) async {
  const total = 5;
  final entries = <LayoutPreloadEntry>[];
  for (var n = 1; n <= total; n++) {
    final cropped = await cache.getLayoutTexture(config, n);
    // Even on cropped failure, try full — the cards only need _full.png,
    // and the cropped PNG is consumed by future slices that may not be
    // wired yet.
    final full = await cache.getLayoutTextureFull(config, n);

    final firstWarning = cropped.ok ? full.warning : cropped.warning;
    entries.add(LayoutPreloadEntry(
      n: n,
      ok: cropped.ok && full.ok,
      warning: firstWarning,
    ));
    onProgress?.call(n, total);
  }
  return LayoutPreloadResult(entries);
}
