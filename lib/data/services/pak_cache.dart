import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart';

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
/// RR_VHS_Tool.py:5096-5535, scoped down to the file-extraction primitives —
/// in-memory image decoding (thumbnails, previews, layout textures) is
/// deferred to a later slice once we have a DXT1 decoder.
///
/// Cache directory is `<workingDir>/.pak_cache/`, persistent across builds.
/// Extraction is idempotent: if the requested path already exists in the
/// cache it is returned without invoking repak.
class PakCache {
  final String workingDir;

  PakCache(this.workingDir);

  /// Persistent cache root. Equivalent to Python's `pak_cache._extract_dir`
  /// (RR_VHS_Tool.py:5108) — repak preserves the internal pak path under it.
  String get extractDir => p.join(workingDir, '.pak_cache');

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
}
