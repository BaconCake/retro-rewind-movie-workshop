import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/constants/genres.dart';
import '../../core/constants/uexp_template.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/texture_replacement.dart';
import '../../domain/repositories/texture_injector.dart';
import '../services/image_preparer.dart';
import '../services/pak_cache.dart';
import '../services/texture_cloner.dart';

/// Path inside the base pak that holds all background texture folders
/// (`T_Bkg_Hor`, `T_Bkg_Act`, etc.).  RR_VHS_Tool.py:5607-5608 mirrors this.
const String _kBackgroundPakPrefix =
    'RetroRewind/Content/VideoStore/asset/prop/vhs/Background';

/// Bundle of bytes ready to write for a single injected texture slot.
/// Returned by [TextureInjectorImpl.composeArtifacts] so the byte-shuffling
/// logic can be tested without invoking texconv.
class InjectionArtifacts {
  final Uint8List uasset;
  final Uint8List uexp;
  final Uint8List ubulk;

  const InjectionArtifacts({
    required this.uasset,
    required this.uexp,
    required this.ubulk,
  });
}

class TextureInjectorImpl implements TextureInjector {
  final PakCache pakCache;
  final ImagePreparer imagePreparer;

  TextureInjectorImpl({
    required this.pakCache,
    this.imagePreparer = const ImagePreparer(),
  });

  @override
  Future<void> inject({
    required AppConfig config,
    required String workRoot,
    required String textureName,
    required String genreCode,
    required TextureReplacement replacement,
  }) async {
    if (config.texconv.isEmpty || !File(config.texconv).existsSync()) {
      throw StateError(
          'texconv.exe path missing or invalid: "${config.texconv}"');
    }
    if (!File(replacement.path).existsSync()) {
      throw FileSystemException(
          'Source image not found', replacement.path);
    }

    final isNewRelease = textureName.startsWith('T_New_');
    // T_New textures live in the same `T_Bkg_<code>` folder as the bkg
    // textures — UE5 keeps NR covers next to genre covers on disk.
    final folder = 'T_Bkg_$genreCode';

    // Pull the whole genre's background folder out of the base pak.  Mirrors
    // Python's `pak_cache.get_base_files(texture)` (RR_VHS_Tool.py:13959).
    final baseRes = await pakCache.extractFolder(
        config, '$_kBackgroundPakPrefix/$folder/');
    if (!baseRes.ok) {
      throw StateError(
          'Could not extract base files for $folder: ${baseRes.warning}');
    }
    final baseDir = baseRes.path!;

    // For T_New on a genre with no base-game NR textures (Romance/Western),
    // also pull Horror's folder so we can clone `T_New_Hor_01` cross-genre.
    // RR_VHS_Tool.py:5745-5793.
    final horBaseDir = await _maybeExtractHorForCrossGenre(
        config, isNewRelease, genreCode);

    // 1+2. Get the DDS bytes for this slot — either from the on-disk cache
    // (skips prepare+texconv when source image + crop params haven't
    // changed since last build) or by running the full pipeline.
    final ddsBytes = await _ddsForReplacement(
      config: config,
      textureName: textureName,
      replacement: replacement,
      isNewRelease: isNewRelease,
    );

    // 3. Read base uasset and base uexp.
    //
    // Four flavours of resolution:
    //   * 3-digit NR (`T_New_<code>_<NN:03d>`, v1.8.2+): always clone from
    //     `T_New_Hor_01` via [cloneTexture3digit] — base game ships only
    //     2-digit T_New slots, so the target name doesn't exist in any
    //     genre's folder.  Mirrors Python's `prepare_nr_donor_in_cache`
    //     + `_t_new_donor_for` (RR_VHS_Tool.py:2286-2384).
    //   * 2-digit NR, in-range (`tex_num <= base_new`): direct extract
    //     from the genre folder — legacy co-inject (Change 1, v1.8.2.1).
    //   * 2-digit NR, out-of-range (`tex_num > base_new`): clone from
    //     `T_New_Hor_01` via [patchLegacy2DigitUasset] (length-preserving
    //     rename, Change 2 / v1.8.2.2 — RR_VHS_Tool.py:2484-2561).
    //   * Custom 3-digit T_Bkg: legacy resolver — walks back through the
    //     genre's 2-digit base slots and clones via [cloneTexture3digit].
    final dstSlotNum = _slotNumberFromName(textureName);
    if (dstSlotNum == null) {
      throw FormatException(
          'Could not parse slot number from $textureName');
    }
    final isThreeDigitNr =
        isNewRelease && _isThreeDigitTextureName(textureName);
    final isTwoDigitNr = isNewRelease && !isThreeDigitNr;

    final Uint8List baseUasset;
    final Uint8List baseUexp;
    if (isThreeDigitNr) {
      final donor = await _readNrHorDonor(config);
      baseUasset = cloneTexture3digit(
        srcData: donor.uasset,
        srcCode: 'Hor',
        srcNum: 1,
        dstCode: genreCode,
        dstNum: dstSlotNum,
      );
      // uexp + ubulk are pixel-data containers — name-independent, so
      // verbatim copy from the Hor donor is correct (Python uses
      // `shutil.copy2` for the same reason at RR_VHS_Tool.py:2371).
      baseUexp = donor.uexp;
    } else if (isTwoDigitNr) {
      // Try direct extract from the target genre's folder first (in-range
      // case — base game has the file).  If it's missing, the slot is
      // out-of-range relative to the genre's `base_new_count`; synthesize
      // it via length-preserving clone of T_New_Hor_01.
      final directUa = File(p.join(baseDir, '$textureName.uasset'));
      final directUe = File(p.join(baseDir, '$textureName.uexp'));
      if (await directUa.exists() && await directUe.exists()) {
        baseUasset = await directUa.readAsBytes();
        baseUexp = await directUe.readAsBytes();
      } else {
        final donor = await _readNrHorDonor(config);
        baseUasset = patchLegacy2DigitUasset(
          srcData: donor.uasset,
          srcCode: 'Hor',
          srcNum: 1,
          dstCode: genreCode,
          dstNum: dstSlotNum,
        );
        baseUexp = donor.uexp;
      }
    } else {
      baseUasset = await _resolveUasset(
          baseDir: baseDir,
          horBaseDir: horBaseDir,
          textureName: textureName,
          genreCode: genreCode,
          dstSlotNum: dstSlotNum,
          isNewRelease: isNewRelease);

      baseUexp = await _resolveUexp(
          baseDir: baseDir,
          horBaseDir: horBaseDir,
          textureName: textureName,
          dstSlotNum: dstSlotNum,
          isNewRelease: isNewRelease);
    }

    final artifacts = composeArtifacts(
      ddsBytes: ddsBytes,
      baseUexp: baseUexp,
      baseUasset: baseUasset,
    );

    // 4. Write outputs into the new pak's mirror folder.
    final destDir = Directory(p.join(workRoot, 'RetroRewind', 'Content',
        'VideoStore', 'asset', 'prop', 'vhs', 'Background', folder));
    await destDir.create(recursive: true);
    await Future.wait([
      File(p.join(destDir.path, '$textureName.uasset'))
          .writeAsBytes(artifacts.uasset),
      File(p.join(destDir.path, '$textureName.uexp'))
          .writeAsBytes(artifacts.uexp),
      File(p.join(destDir.path, '$textureName.ubulk'))
          .writeAsBytes(artifacts.ubulk),
    ]);
  }

  /// Resolve the texconv DDS bytes for [textureName].  On a cache hit
  /// (source path mtime + crop params unchanged since last build), reads
  /// the saved DDS and skips both the pure-Dart prepare AND the texconv
  /// subprocess — the two slowest phases per slot.  Cache lives under
  /// `<workingDir>/.tex_cache/` next to the existing PakCache.
  Future<Uint8List> _ddsForReplacement({
    required AppConfig config,
    required String textureName,
    required TextureReplacement replacement,
    required bool isNewRelease,
  }) async {
    final cacheKey = await _texCacheKey(replacement, isNewRelease: isNewRelease);
    final cacheDir = Directory(p.join(pakCache.workingDir, '.tex_cache'));
    final cacheFile = File(p.join(cacheDir.path, '$cacheKey.dds'));
    if (await cacheFile.exists()) {
      return cacheFile.readAsBytes();
    }

    // Run prepare + texconv in a worker isolate.  This:
    //   * keeps the main isolate free, so the spinner spins and the log
    //     scroll stays smooth during a build;
    //   * gives true multicore parallelism — multiple chunked workers each
    //     spawn their own isolate, so cubic resize and PNG encode actually
    //     run in parallel instead of taking turns on the main isolate.
    final ddsBytes = await Isolate.run(() => _prepareAndTexconvInIsolate(
          sourcePath: replacement.path,
          offsetX: replacement.offsetX,
          offsetY: replacement.offsetY,
          zoom: replacement.zoom,
          isFullCanvas: isNewRelease,
          texconvPath: config.texconv,
          textureName: textureName,
        ));

    // Persist for next build.  Best-effort — a write failure shouldn't
    // abort the build, just means we'll re-prepare next time.
    try {
      await cacheDir.create(recursive: true);
      await cacheFile.writeAsBytes(ddsBytes);
    } catch (_) {}

    return ddsBytes;
  }

  /// Stable per-slot cache key derived from the replacement source's mtime
  /// + crop params + canvas fit.  Source path *value* is included so
  /// changing the file behind the same params still busts the cache.
  /// FNV-1a 64-bit hash — not cryptographic but deterministic across runs
  /// (Object.hashAll is randomised, which would invalidate the cache every
  /// app restart).
  Future<String> _texCacheKey(
      TextureReplacement r, {required bool isNewRelease}) async {
    int mtimeMs;
    try {
      mtimeMs = (await File(r.path).stat()).modified.millisecondsSinceEpoch;
    } catch (_) {
      mtimeMs = 0;
    }
    final raw = '${r.path}|$mtimeMs|${r.offsetX}|${r.offsetY}|${r.zoom}|'
        '${isNewRelease ? "nr" : "bkg"}';
    return _fnv1a64Hex(raw);
  }

  /// Build the texconv argv used in production injection.  Public so tests
  /// can lock the exact flag list — accidental flag drift would silently
  /// alter the output bytes.  RR_VHS_Tool.py:5621-5622.
  static List<String> texconvArgs({
    required String texconv,
    required String tmpDir,
    required String inputPng,
  }) {
    return [
      texconv,
      '-f', 'DXT1',
      '-w', '$kTexconvWidth',
      '-h', '$kTexconvHeight',
      '-if', 'LINEAR',
      '-srgb',
      '-o', tmpDir,
      '-y', inputPng,
    ];
  }

  /// Pure byte-shuffling: given the texconv DDS output and the base files,
  /// produce the bytes to write for uasset / uexp / ubulk.
  ///
  /// Logic mirrors RR_VHS_Tool.py:5636-5699:
  /// - Strip the DDS header (128 or 148 bytes for DX10 extended).
  /// - Pad or truncate the raw pixel data to [kTNewUbulkSize] for ubulk.
  /// - If the base uexp is exactly the 1702-byte template, patch the inline
  ///   mip pixel data with mips 5-11 from the DDS.  Otherwise leave the base
  ///   uexp untouched (existing base-game slots ship a much larger uexp and
  ///   Python preserves it).
  /// - uasset is copied verbatim.
  static InjectionArtifacts composeArtifacts({
    required Uint8List ddsBytes,
    required Uint8List baseUexp,
    required Uint8List baseUasset,
  }) {
    final ddsHeaderSize = _ddsHeaderSize(ddsBytes);
    final raw = Uint8List.sublistView(ddsBytes, ddsHeaderSize);

    // ubulk: pad with zeros or truncate to the canonical 5-mip size.
    final ubulk = Uint8List(kTNewUbulkSize);
    final copyLen = raw.length < ubulk.length ? raw.length : ubulk.length;
    ubulk.setRange(0, copyLen, raw);

    // uexp: only patch inline mips when using the empty template.  Existing
    // base-game uexps are kept verbatim because Python does the same — its
    // `if len(uexp_data) == 1702` guard skips the patch otherwise
    // (RR_VHS_Tool.py:5680).
    Uint8List uexp;
    if (baseUexp.length == _kTBkgUexpTemplateSize) {
      uexp = Uint8List.fromList(baseUexp);
      var ddsMipOffset = kTNewUbulkSize;
      for (final entry in kUexpInlineMipMap) {
        final (_, uexpOff, mipSize) = entry;
        final srcEnd = ddsMipOffset + mipSize;
        if (srcEnd <= raw.length) {
          uexp.setRange(uexpOff, uexpOff + mipSize, raw, ddsMipOffset);
        }
        ddsMipOffset += mipSize;
      }
    } else {
      uexp = Uint8List.fromList(baseUexp);
    }

    return InjectionArtifacts(
      uasset: Uint8List.fromList(baseUasset),
      uexp: uexp,
      ubulk: ubulk,
    );
  }

  /// DDS header size: 128 for the standard DDS_HEADER, or 148 when the file
  /// has a DX10 extended header (signaled by FourCC `DX10` at offset 84).
  /// RR_VHS_Tool.py:5640-5645.
  static int _ddsHeaderSize(Uint8List dds) {
    if (dds.length > 148) {
      // Bytes 84..87 are the dwFourCC field of DDS_PIXELFORMAT.
      if (dds[84] == 0x44 && // 'D'
          dds[85] == 0x58 && // 'X'
          dds[86] == 0x31 && // '1'
          dds[87] == 0x30) { // '0'
        return 148;
      }
    }
    return 128;
  }

  /// Write a placeholder for a custom slot that has a DataTable row but no
  /// user-supplied image.  Mirrors RR_VHS_Tool.py:13967-14005:
  ///   * uasset: cloned (or copied) from the closest preceding base slot.
  ///   * uexp:   the canonical empty template (1702 bytes).
  ///   * ubulk:  zero-filled (renders as a black background in-game).
  ///
  /// The point of writing these files at all — rather than just leaving the
  /// slot referenced and hoping for a fallback — is that the cloned uasset
  /// carries the *new* slot's FName encoding, so the engine actually finds
  /// the asset under its 3-digit name.  Without this, the DataTable row's
  /// reference resolves to nothing.
  Future<void> writePlaceholder({
    required AppConfig config,
    required String workRoot,
    required String textureName,
    required String genreCode,
  }) async {
    final folder = 'T_Bkg_$genreCode';
    final baseRes = await pakCache.extractFolder(
        config, '$_kBackgroundPakPrefix/$folder/');
    if (!baseRes.ok) {
      throw StateError(
          'Could not extract base files for $folder: ${baseRes.warning}');
    }
    final baseDir = baseRes.path!;

    final dstSlotNum = _slotNumberFromName(textureName);
    if (dstSlotNum == null) {
      throw FormatException(
          'Could not parse slot number from $textureName');
    }
    // writePlaceholder is only called for slots without a user image —
    // currently always T_Bkg.  T_New placeholders are intentionally skipped
    // (NR slot without a cover → engine falls back to base game), so
    // isNewRelease=false here, matching the historical contract.
    final baseUasset = await _resolveUasset(
        baseDir: baseDir,
        textureName: textureName,
        genreCode: genreCode,
        dstSlotNum: dstSlotNum,
        isNewRelease: false);

    final destDir = Directory(p.join(workRoot, 'RetroRewind', 'Content',
        'VideoStore', 'asset', 'prop', 'vhs', 'Background', folder));
    await destDir.create(recursive: true);
    await Future.wait([
      File(p.join(destDir.path, '$textureName.uasset'))
          .writeAsBytes(baseUasset),
      File(p.join(destDir.path, '$textureName.uexp'))
          .writeAsBytes(kTBkgUexpTemplate),
      File(p.join(destDir.path, '$textureName.ubulk'))
          .writeAsBytes(Uint8List(kTNewUbulkSize)),
    ]);
  }

  /// Pick the right uasset bytes for [textureName], either:
  ///   * the existing base-game file at `<baseDir>/<textureName>.uasset`
  ///     (base-game slots, name uses 2-digit numbering), **or**
  ///   * a cloned-from-preceding-base-slot uasset (custom 3-digit slots), **or**
  ///   * a cross-genre clone of `T_New_Hor_01.uasset` (T_New slot in a genre
  ///     with `newCount==0`, e.g. Romance/Western — RR_VHS_Tool.py:5745-5793).
  ///
  /// Mirrors the search order in RR_VHS_Tool.py:5697-5793.
  Future<Uint8List> _resolveUasset({
    required String baseDir,
    String? horBaseDir,
    required String textureName,
    required String genreCode,
    required int dstSlotNum,
    required bool isNewRelease,
  }) async {
    final direct = File(p.join(baseDir, '$textureName.uasset'));
    if (await direct.exists()) {
      return direct.readAsBytes();
    }

    // Walk preceding 2-digit slots to find a clone source.  Python only
    // checks the first iteration when dstSlotNum-1 is already in the base
    // game range (`if cand_num <= base_count_fb: break`), so we mirror that
    // tiny optimisation.
    final genre = kGenres.firstWhere(
      (g) => g.code == genreCode,
      orElse: () => throw StateError('Unknown genre code "$genreCode"'),
    );
    final baseCount = isNewRelease ? genre.newCount : genre.bkgCount;

    for (var candNum = dstSlotNum - 1; candNum > 0; candNum--) {
      final candName = candNum < 100
          ? '${_textureNameStem(textureName)}_${candNum.toString().padLeft(2, '0')}'
          : '${_textureNameStem(textureName)}_$candNum';
      final candFile = File(p.join(baseDir, '$candName.uasset'));
      if (await candFile.exists()) {
        final src = await candFile.readAsBytes();
        return cloneTexture3digit(
          srcData: src,
          srcCode: genreCode,
          srcNum: candNum,
          dstCode: genreCode,
          dstNum: dstSlotNum,
        );
      }
      if (candNum <= baseCount) break;
    }

    // Fallback: clone from the genre's last base slot — same genre, no
    // cross-genre patch yet.  Only fires for T_Bkg or for T_New genres with
    // newCount > 0.
    if (baseCount > 0) {
      final lastBaseName = isNewRelease
          ? '${_textureNameStem(textureName)}_${baseCount.toString().padLeft(2, '0')}'
          : '${_textureNameStem(textureName)}_${baseCount.toString().padLeft(2, '0')}';
      final lastBaseFile = File(p.join(baseDir, '$lastBaseName.uasset'));
      if (await lastBaseFile.exists()) {
        final src = await lastBaseFile.readAsBytes();
        return cloneTexture3digit(
          srcData: src,
          srcCode: genreCode,
          srcNum: baseCount,
          dstCode: genreCode,
          dstNum: dstSlotNum,
        );
      }
    }

    // Cross-genre fallback for T_New on newCount==0 genres (Romance/Western):
    // clone T_New_Hor_01 from Horror's folder, retargeting genre code.
    if (isNewRelease && horBaseDir != null) {
      final horSrc = File(p.join(horBaseDir, 'T_New_Hor_01.uasset'));
      if (await horSrc.exists()) {
        final src = await horSrc.readAsBytes();
        return cloneTexture3digit(
          srcData: src,
          srcCode: 'Hor',
          srcNum: 1,
          dstCode: genreCode,
          dstNum: dstSlotNum,
        );
      }
    }

    throw FileSystemException(
        'No base uasset and no clonable preceding slot for $textureName',
        baseDir);
  }

  /// Pick the right uexp bytes for [textureName].  Order:
  ///   1. Direct file in [baseDir].
  ///   2. T_New only: walk preceding NR slots in the same genre (the empty
  ///      1702-byte template would zero out lower mips and break standee
  ///      close-up rendering — RR_VHS_Tool.py:443).
  ///   3. T_New only: cross-genre fallback to `T_New_Hor_01.uexp`.
  ///   4. T_Bkg only: empty 1702-byte template.
  Future<Uint8List> _resolveUexp({
    required String baseDir,
    String? horBaseDir,
    required String textureName,
    required int dstSlotNum,
    required bool isNewRelease,
  }) async {
    final direct = File(p.join(baseDir, '$textureName.uexp'));
    if (await direct.exists()) return direct.readAsBytes();

    if (isNewRelease) {
      // Walk preceding within-genre NR uexps.
      for (var n = dstSlotNum - 1; n > 0; n--) {
        final padded = n < 100 ? n.toString().padLeft(2, '0') : n.toString();
        final cand = File(p.join(
            baseDir, '${_textureNameStem(textureName)}_$padded.uexp'));
        if (await cand.exists()) return cand.readAsBytes();
      }
      // Cross-genre fallback for newCount==0 genres.
      if (horBaseDir != null) {
        final horSrc = File(p.join(horBaseDir, 'T_New_Hor_01.uexp'));
        if (await horSrc.exists()) return horSrc.readAsBytes();
      }
      throw FileSystemException(
          'No base uexp and no clonable preceding slot for $textureName',
          baseDir);
    }

    return kTBkgUexpTemplate;
  }

  /// For T_New on a genre with `newCount==0`, extract Horror's `T_Bkg_Hor`
  /// folder so the caller can clone `T_New_Hor_01.*` cross-genre.  Returns
  /// the extracted folder path, or null when not applicable.
  ///
  /// Only used by the legacy 2-digit resolver path now — 3-digit NRs go
  /// through [_readNrHorDonor] regardless of target genre's newCount.
  Future<String?> _maybeExtractHorForCrossGenre(
      AppConfig config, bool isNewRelease, String genreCode) async {
    if (!isNewRelease) return null;
    if (genreCode == 'Hor') return null;
    final genre = kGenres.firstWhere((g) => g.code == genreCode,
        orElse: () => throw StateError('Unknown genre code "$genreCode"'));
    if (genre.newCount > 0) return null;
    final res = await pakCache.extractFolder(
        config, '$_kBackgroundPakPrefix/T_Bkg_Hor/');
    if (!res.ok) {
      throw StateError(
          'Could not extract T_Bkg_Hor for cross-genre clone: ${res.warning}');
    }
    return res.path!;
  }

  /// Pull the canonical NR donor pair (`T_New_Hor_01.uasset/.uexp`) out of
  /// the base pak via [PakCache].  Both files always exist (Horror has
  /// `newCount = 4`).  Pure port of the donor side of
  /// `prepare_nr_donor_in_cache` (RR_VHS_Tool.py:2311-2384) — minus the
  /// on-disk pre-materialisation of the cloned target file (we clone +
  /// write straight into the build's workRoot from the inject() caller).
  Future<({Uint8List uasset, Uint8List uexp})> _readNrHorDonor(
      AppConfig config) async {
    const donorBase =
        '$_kBackgroundPakPrefix/T_Bkg_Hor/T_New_Hor_01';
    final uaRes = await pakCache.extractFile(config, '$donorBase.uasset');
    final ueRes = await pakCache.extractFile(config, '$donorBase.uexp');
    if (!uaRes.ok || !ueRes.ok) {
      throw StateError(
        'Could not extract T_New_Hor_01 donor: '
        'uasset=${uaRes.warning}, uexp=${ueRes.warning}',
      );
    }
    final uasset = await File(uaRes.path!).readAsBytes();
    final uexp = await File(ueRes.path!).readAsBytes();
    return (uasset: uasset, uexp: uexp);
  }
}

/// Run the slow part of the inject pipeline (PNG resize+encode then
/// texconv subprocess) inside the calling isolate.  Top-level so it can
/// be passed across the [Isolate.run] boundary; the main isolate stays
/// free during the call.
Future<Uint8List> _prepareAndTexconvInIsolate({
  required String sourcePath,
  required int offsetX,
  required int offsetY,
  required double zoom,
  required bool isFullCanvas,
  required String texconvPath,
  required String textureName,
}) async {
  // 1. Pure-Dart resize/pad (slow — package:image cubic interpolation +
  //    PNG encode).  Lives entirely in this isolate so the main isolate
  //    can keep rendering.
  final sourceBytes = await File(sourcePath).readAsBytes();
  final pngBytes = const ImagePreparer().encode(
    sourceBytes: sourceBytes,
    offsetX: offsetX,
    offsetY: offsetY,
    zoom: zoom,
    fit: isFullCanvas ? CanvasFit.fullCanvas : CanvasFit.bkg,
  );

  final tmpDir = await Directory.systemTemp.createTemp('rr_iso_${textureName}_');
  try {
    final pngPath = p.join(tmpDir.path, '$textureName.png');
    await File(pngPath).writeAsBytes(pngBytes);

    // 2. texconv subprocess.  Argv must match Python (RR_VHS_Tool.py:
    //    5621-5622) so output bytes line up byte-for-byte.
    final r = await Process.run(texconvPath, [
      '-f', 'DXT1',
      '-w', '$kTexconvWidth',
      '-h', '$kTexconvHeight',
      '-if', 'LINEAR',
      '-srgb',
      '-o', tmpDir.path,
      '-y', pngPath,
    ]);
    if (r.exitCode != 0) {
      final stderr = (r.stderr ?? '').toString().trim();
      throw StateError('texconv failed: $stderr');
    }

    final ddsPath = p.join(tmpDir.path, '$textureName.dds');
    final ddsFile = File(ddsPath);
    if (!await ddsFile.exists()) {
      throw const FileSystemException(
          'texconv reported success but produced no DDS file');
    }
    return ddsFile.readAsBytes();
  } finally {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {/* best-effort */}
  }
}

/// FNV-1a 64-bit hash → 16-char hex.  Stable across runs (unlike Dart's
/// randomised Object.hashAll) so the texture cache survives app restarts.
String _fnv1a64Hex(String s) {
  const fnvPrime = 0x100000001b3;
  const fnvOffset = 0xcbf29ce484222325;
  var hash = fnvOffset;
  for (final cu in s.codeUnits) {
    hash ^= cu;
    hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Strip the trailing `_NN` / `_NNN` from a texture name.  E.g.
/// `T_Bkg_Wst_001` → `T_Bkg_Wst`.  Returns the input unchanged if it
/// doesn't contain at least one underscore — callers should validate
/// upstream.
String _textureNameStem(String name) {
  final idx = name.lastIndexOf('_');
  return idx <= 0 ? name : name.substring(0, idx);
}

/// True when [name] ends with a 3-digit slot number (`T_New_Dra_001`,
/// `T_Bkg_Hor_017`, etc.).  Used by the inject path to route NR slots
/// through the Hor donor clone (v1.8.2 — RR_VHS_Tool.py:2330).  Returns
/// false for 2-digit names (legacy co-inject) and for malformed inputs.
bool _isThreeDigitTextureName(String name) {
  final idx = name.lastIndexOf('_');
  if (idx <= 0 || idx >= name.length - 1) return false;
  final tail = name.substring(idx + 1);
  return tail.length == 3 && int.tryParse(tail) != null;
}

/// Parse the trailing slot number out of `T_Bkg_<code>_<num>`.  Returns
/// null when the trailing segment can't be parsed as an int.
int? _slotNumberFromName(String name) {
  final idx = name.lastIndexOf('_');
  if (idx <= 0 || idx == name.length - 1) return null;
  return int.tryParse(name.substring(idx + 1));
}

const int kTexconvWidth = 1024;
const int kTexconvHeight = 2048;
const int _kTBkgUexpTemplateSize = 1702;
