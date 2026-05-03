import 'dart:io';
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

    final tmpDir = await Directory.systemTemp
        .createTemp('rr_inject_${textureName}_');
    try {
      // 1. Resize / pad the user image onto a 1024×2048 PNG.
      final preparedPng = p.join(tmpDir.path, '$textureName.png');
      await imagePreparer.prepare(
        inputPath: replacement.path,
        outputPath: preparedPng,
        offsetX: replacement.offsetX,
        offsetY: replacement.offsetY,
        zoom: replacement.zoom,
      );

      // 2. texconv → DDS in the same tmp folder.  Argv must match Python
      // (RR_VHS_Tool.py:5621-5622) so output bytes line up byte-for-byte.
      final args = texconvArgs(
          texconv: config.texconv, tmpDir: tmpDir.path, inputPng: preparedPng);
      final r = await Process.run(args[0], args.sublist(1));
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
      final ddsBytes = await ddsFile.readAsBytes();

      // 3. Read base uasset (or clone from a preceding base slot for custom
      //    3-digit names) and base uexp (or fall back to the empty template).
      //    Mirrors RR_VHS_Tool.py:5670-5740.
      final dstSlotNum = _slotNumberFromName(textureName);
      if (dstSlotNum == null) {
        throw FormatException(
            'Could not parse slot number from $textureName');
      }
      final baseUasset = await _resolveUasset(
          baseDir: baseDir,
          textureName: textureName,
          genreCode: genreCode,
          dstSlotNum: dstSlotNum);

      final uexpFile = File(p.join(baseDir, '$textureName.uexp'));
      final baseUexp = await uexpFile.exists()
          ? await uexpFile.readAsBytes()
          : kTBkgUexpTemplate;

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
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {/* best-effort */}
    }
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
    final baseUasset = await _resolveUasset(
        baseDir: baseDir,
        textureName: textureName,
        genreCode: genreCode,
        dstSlotNum: dstSlotNum);

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
  ///   * a cloned-from-preceding-base-slot uasset (custom 3-digit slots).
  ///
  /// Mirrors the search order in RR_VHS_Tool.py:5697-5740.
  Future<Uint8List> _resolveUasset({
    required String baseDir,
    required String textureName,
    required String genreCode,
    required int dstSlotNum,
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
    final baseCount = genre.bkgCount;

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

    // Fallback: clone from the genre's last base slot.  Only T_Bkg textures
    // are reachable here in slice 3b; T_New / cross-genre cloning is slice 3c.
    if (textureName.startsWith('T_Bkg_')) {
      final lastBaseName =
          '${_textureNameStem(textureName)}_${baseCount.toString().padLeft(2, '0')}';
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

    throw FileSystemException(
        'No base uasset and no clonable preceding slot for $textureName',
        baseDir);
  }
}

/// Strip the trailing `_NN` / `_NNN` from a texture name.  E.g.
/// `T_Bkg_Wst_001` → `T_Bkg_Wst`.  Returns the input unchanged if it
/// doesn't contain at least one underscore — callers should validate
/// upstream.
String _textureNameStem(String name) {
  final idx = name.lastIndexOf('_');
  return idx <= 0 ? name : name.substring(0, idx);
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
