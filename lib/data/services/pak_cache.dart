import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart';
import 'dxt1_decoder.dart';

/// Result of a PakCache extraction call. On success, [path] points at the
/// on-disk location; on failure, [warning] carries a human-readable reason
/// (typically prefixed with `[E0NN]`) and [path] is null.
class PakCacheResult {
  final String? path;
  final String? warning;
  final int? sizeBytes;

  const PakCacheResult.ok(this.path, this.sizeBytes) : warning = null;
  const PakCacheResult.skipped(this.warning)
      : path = null,
        sizeBytes = null;

  bool get ok => path != null;
}

/// Cached read access to the base game pak. Mirrors `PakCache` from
/// RR_VHS_Tool.py:5096-5535: file extraction primitives plus DXT1-decoded
/// layout textures saved as a persistent PNG cache.
///
/// Cache directory is `<workingDir>/.pak_cache/`, persistent across builds.
/// Extraction is idempotent: if the requested path already exists in the
/// cache it is returned without invoking repak.
///
/// The layout PNG cache lives at `<workingDir>/layout_cache/` to match the
/// Python tool's location — users who switch between tools share the same
/// pre-decoded thumbnails and never pay the DXT1 decode cost twice.
class PakCache {
  final String workingDir;

  PakCache(this.workingDir);

  /// Persistent cache root. Equivalent to Python's `pak_cache._extract_dir`
  /// (RR_VHS_Tool.py:5108) — repak preserves the internal pak path under it.
  String get extractDir => p.join(workingDir, '.pak_cache');

  /// Persistent PNG cache for decoded layout textures, shared with the
  /// Python tool (`SCRIPT_DIR/layout_cache/`).  See [getLayoutTexture] /
  /// [getLayoutTextureFull].
  String get layoutCacheDir => p.join(workingDir, 'layout_cache');

  String _cachedPathFor(String internalPath) =>
      p.join(extractDir, internalPath.replaceAll('/', p.separator));

  /// Extract a single file from the base pak (e.g. `RetroRewind/AssetRegistry.bin`).
  /// On cache hit, returns immediately without invoking repak. On cache miss,
  /// runs `repak unpack -o <extractDir> -f -i <internalPath> <basePak>` with a
  /// 30 s timeout (matches Python).
  Future<PakCacheResult> extractFile(
      AppConfig config, String internalPath) async {
    final pre = _checkConfig(config);
    if (pre != null) return pre;

    final cachedPath = _cachedPathFor(internalPath);
    final cachedFile = File(cachedPath);

    if (!await cachedFile.exists()) {
      await Directory(extractDir).create(recursive: true);
      try {
        final res = await Process.run(
          config.repak,
          [
            'unpack',
            '-o', extractDir,
            '-f',
            '-i', internalPath,
            config.baseGamePak,
          ],
        ).timeout(const Duration(seconds: 30));
        if (res.exitCode != 0 && !await cachedFile.exists()) {
          // repak sometimes returns non-zero on harmless tail errors (e.g.
          // trying to rename pak after a successful extract). Only treat as
          // failure if the file we asked for is actually missing.
          final stderr = (res.stderr ?? '').toString().trim();
          return PakCacheResult.skipped(
              '[E011] repak unpack exit ${res.exitCode}'
              '${stderr.isEmpty ? '' : ': $stderr'}');
        }
      } catch (e) {
        return PakCacheResult.skipped('[E011] repak unpack threw: $e');
      }
    }

    if (!await cachedFile.exists()) {
      return PakCacheResult.skipped(
          '[E011] file not at $cachedPath after unpack');
    }
    final size = await cachedFile.length();
    return PakCacheResult.ok(cachedPath, size);
  }

  /// Extract a folder prefix (e.g. `RetroRewind/Content/.../data/`) in a
  /// single repak call. Mirrors the batch path used by Python for thumbnails
  /// and DataTables. Returns the on-disk root of the extraction (the prefix
  /// resolved under `extractDir`); the caller walks it for individual files.
  ///
  /// Idempotent: skips the repak call if the resolved root already exists.
  /// Uses a 120 s timeout to match Python's larger-batch extractions.
  Future<PakCacheResult> extractFolder(
      AppConfig config, String internalPrefix) async {
    final pre = _checkConfig(config);
    if (pre != null) return pre;

    // Normalise: repak wants forward slashes and a trailing slash on folders.
    final normalised = internalPrefix.endsWith('/')
        ? internalPrefix
        : '$internalPrefix/';
    final root = _cachedPathFor(normalised);
    final rootDir = Directory(root);

    if (!await rootDir.exists()) {
      await Directory(extractDir).create(recursive: true);
      try {
        final res = await Process.run(
          config.repak,
          [
            'unpack',
            '-o', extractDir,
            '-f',
            '-i', normalised,
            config.baseGamePak,
          ],
        ).timeout(const Duration(seconds: 120));
        if (res.exitCode != 0 && !await rootDir.exists()) {
          final stderr = (res.stderr ?? '').toString().trim();
          return PakCacheResult.skipped(
              '[E011] repak unpack exit ${res.exitCode}'
              '${stderr.isEmpty ? '' : ': $stderr'}');
        }
      } catch (e) {
        return PakCacheResult.skipped('[E011] repak unpack threw: $e');
      }
    }

    if (!await rootDir.exists()) {
      return PakCacheResult.skipped(
          '[E011] folder not at $root after unpack');
    }
    // Strip trailing separator so the returned path joins cleanly with
    // child file names via p.join.
    final cleanRoot = root.endsWith(p.separator)
        ? root.substring(0, root.length - 1)
        : root;
    return PakCacheResult.ok(cleanRoot, null);
  }

  /// Convenience: extract + read the file's bytes. Returns null on failure;
  /// inspect via [extractFile] if you need the warning text.
  Future<Uint8List?> readFile(AppConfig config, String internalPath) async {
    final r = await extractFile(config, internalPath);
    if (r.path == null) return null;
    return File(r.path!).readAsBytes();
  }

  PakCacheResult? _checkConfig(AppConfig config) {
    if (config.baseGamePak.isEmpty ||
        !File(config.baseGamePak).existsSync()) {
      return PakCacheResult.skipped(
          'base_game_pak not configured or missing on disk');
    }
    if (config.repak.isEmpty || !File(config.repak).existsSync()) {
      return PakCacheResult.skipped(
          'repak.exe not configured or missing on disk');
    }
    return null;
  }

  // ── Layout textures (slice 4f) ─────────────────────────────────────────
  //
  // Mirrors `PakCache.get_layout_texture` and `get_layout_texture_full`
  // (RR_VHS_Tool.py:5296-5410).  Each base-game `T_Layout_NN_bc.ubulk`
  // contains a 2048×2048 DXT1 mip0 in the first 2,097,152 bytes.  We
  // decode it once, save the result as a PNG to `layout_cache/`, and
  // serve future calls from the PNG cache instead of paying for repak +
  // DXT1 each app start.

  /// Internal pak path of `T_Layout_NN_{variant}.ubulk` in the base game.
  static String _layoutUbulkInternalPath(int n, String variant) {
    final nn = n.toString().padLeft(2, '0');
    return 'RetroRewind/Content/VideoStore/asset/prop/vhs/Layout/'
        'T_Layout_${nn}_$variant.ubulk';
  }

  /// Layout mip0 size in bytes — 2048×2048 DXT1 = 4 bytes per 4×4 block ×
  /// (2048/4)² blocks = 2,097,152.  Layout ubulks are larger than this
  /// (subsequent mips trail the mip0), so we always slice off the first
  /// `_kLayoutMip0Bytes`.
  static const int _kLayoutMip0Bytes = 2 * 1024 * 1024;
  static const int _kLayoutSide = 2048;
  // T_Bkg-aligned crop of the layout texture: centre 1024px wide × full
  // 2048 tall.  Used by the in-canvas layout overlay (NR / preview slices).
  static const int _kLayoutCropX = 512;
  static const int _kLayoutCropW = 1024;

  /// Layout texture cropped to T_Bkg dimensions (1024×2048).  Saved to
  /// `<layoutCacheDir>/T_Layout_NN_{variant}.png`.  Pure port of
  /// `get_layout_texture` (RR_VHS_Tool.py:5296-5365).
  Future<PakCacheResult> getLayoutTexture(
    AppConfig config,
    int n, {
    String variant = 'bc',
  }) =>
      _getLayoutTexture(config, n, variant: variant, fullSize: false);

  /// Full 2048×2048 layout texture.  Saved to
  /// `<layoutCacheDir>/T_Layout_NN_{variant}_full.png`.  Pure port of
  /// `get_layout_texture_full` (RR_VHS_Tool.py:5368-5410).
  Future<PakCacheResult> getLayoutTextureFull(
    AppConfig config,
    int n, {
    String variant = 'bc',
  }) =>
      _getLayoutTexture(config, n, variant: variant, fullSize: true);

  Future<PakCacheResult> _getLayoutTexture(
    AppConfig config,
    int n, {
    required String variant,
    required bool fullSize,
  }) async {
    if (n < 1 || n > 5) {
      return PakCacheResult.skipped('layout n out of range: $n (expected 1..5)');
    }
    final nn = n.toString().padLeft(2, '0');
    final pngName =
        fullSize ? 'T_Layout_${nn}_${variant}_full.png' : 'T_Layout_${nn}_$variant.png';
    final pngPath = p.join(layoutCacheDir, pngName);
    final pngFile = File(pngPath);

    // Cache hit — instant return, no repak / DXT1.
    if (await pngFile.exists()) {
      final size = await pngFile.length();
      return PakCacheResult.ok(pngPath, size);
    }

    // Cache miss — extract the ubulk, decode mip0, encode PNG.
    final pre = _checkConfig(config);
    if (pre != null) return pre;

    final internalPath = _layoutUbulkInternalPath(n, variant);
    final extracted = await extractFile(config, internalPath);
    if (!extracted.ok) {
      return PakCacheResult.skipped(
        '[E011] could not extract $internalPath: ${extracted.warning ?? "unknown"}',
      );
    }
    final ubulkBytes = await File(extracted.path!).readAsBytes();
    if (ubulkBytes.lengthInBytes < _kLayoutMip0Bytes) {
      return PakCacheResult.skipped(
        'layout ubulk too small: need $_kLayoutMip0Bytes bytes, '
        'got ${ubulkBytes.lengthInBytes}',
      );
    }
    final mip0 = Uint8List.sublistView(ubulkBytes, 0, _kLayoutMip0Bytes);

    final Uint8List rgba;
    try {
      rgba = decodeDxt1(mip0, _kLayoutSide, _kLayoutSide);
    } catch (e) {
      return PakCacheResult.skipped('layout DXT1 decode failed: $e');
    }

    var image = img.Image.fromBytes(
      width: _kLayoutSide,
      height: _kLayoutSide,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    if (!fullSize) {
      // Crop to centre 1024px wide so the result aligns with T_Bkg's
      // 1024×2048 frame — what the in-canvas overlay expects.
      image = img.copyCrop(
        image,
        x: _kLayoutCropX,
        y: 0,
        width: _kLayoutCropW,
        height: _kLayoutSide,
      );
    }

    await Directory(layoutCacheDir).create(recursive: true);
    final pngBytes = img.encodePng(image);
    await pngFile.writeAsBytes(pngBytes);
    return PakCacheResult.ok(pngPath, pngBytes.length);
  }
}
