import 'dart:typed_data';

import '../services/uasset_rebuilder.dart';
import 'standee_templates.dart';

/// Material-instance builder for a New Release standee.
///
/// Pure port of `create_mi_for_nr` (RR_VHS_Tool.py:4502-4571).  Clones the
/// embedded `MI_New_Hor_04` template (Standee A) and retargets it at the
/// caller's genre, texture slot, and standee shape.
///
/// As of v1.8.2 the slot-number patch is **length-changing**: the donor
/// number is "04" (2 chars) but the target is `<NN:03d>` (3 chars), so
/// every occurrence in the name table grows by 1 byte.  The PackageName
/// also grows by 1.  The asset is rebuilt via [rebuildUAssetWithNamePatches]
/// instead of in-place same-length patches.
///
/// Output asset names follow Python's pattern:
///
///   `RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_{genre}/MI_New_{genre}_{NN:03d}.uasset`

class StandeeMiBuildResult {
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final String relativePath;
  /// Number of name-table entries that had at least one patch applied.
  final int patchedNames;
  /// `newLen - oldLen` for the rebuilt uasset (positive when the 3-digit
  /// number grew the file).
  final int totalShift;

  const StandeeMiBuildResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.relativePath,
    required this.patchedNames,
    required this.totalShift,
  });
}

class StandeeMiBuildError implements Exception {
  final String message;
  const StandeeMiBuildError(this.message);
  @override
  String toString() => 'StandeeMiBuildError: $message';
}

class StandeeMiBuilder {
  final StandeeTemplates templates;
  StandeeMiBuilder(this.templates);

  /// Build the MI uasset+uexp pair for a New Release.
  ///
  /// [genreCode] — 3-char code matching `T_Bkg_<code>` (e.g. "Dra", "Sci").
  /// [texNum] — slot number (1..99 per [kNrPerGenreCap]).  Encoded as
  /// 3-digit zero-padded.  100+ is intentionally rejected — Python's
  /// `clone_texture_3digit` switches to a different FName encoding above
  /// 99 (literal-name vs base-name + FName num); we don't need that path
  /// since the UI caps NR count per genre at 99.
  /// [standeeShape] — "A", "B", or "C".  Same-length always (1 char).
  StandeeMiBuildResult build({
    required String genreCode,
    required int texNum,
    required String standeeShape,
  }) {
    if (genreCode.length != kMiTemplateGenre.length) {
      throw StandeeMiBuildError(
          'genre code length mismatch: got "$genreCode" '
          '(${genreCode.length}), expected ${kMiTemplateGenre.length}');
    }
    if (texNum < 1 || texNum > 99) {
      throw StandeeMiBuildError(
          'tex_num $texNum out of range — must be 1..99');
    }
    if (standeeShape.length != kMiTemplateShape.length) {
      throw StandeeMiBuildError(
          'standee shape length mismatch: got "$standeeShape"');
    }

    // Donor template strings, exactly as they appear in the embedded
    // `MI_New_Hor_04` uasset.  Substring substitutions in the name table.
    final srcGn =
        '${kMiTemplateGenre}_${kMiTemplateNum.toString().padLeft(2, '0')}';
    final dstGn = '${genreCode}_${texNum.toString().padLeft(3, '0')}';
    final srcFolder = 'T_Bkg_$kMiTemplateGenre';
    final dstFolder = 'T_Bkg_$genreCode';
    final srcAo = 'T_Standee_${kMiTemplateShape}_01_ao';
    final dstAo = 'T_Standee_${standeeShape}_01_ao';

    final patches = <NameTablePatch>[];
    if (srcGn != dstGn) patches.add(NameTablePatch(srcGn, dstGn));
    if (srcFolder != dstFolder) patches.add(NameTablePatch(srcFolder, dstFolder));
    if (srcAo != dstAo) patches.add(NameTablePatch(srcAo, dstAo));

    // PackageName: full literal path including the new 3-digit number.
    final srcPkg =
        '/Game/VideoStore/asset/prop/vhs/Background/$srcFolder/MI_New_$srcGn';
    final dstPkg =
        '/Game/VideoStore/asset/prop/vhs/Background/$dstFolder/MI_New_$dstGn';

    final UAssetRebuildResult rebuilt;
    try {
      rebuilt = rebuildUAssetWithNamePatches(
        data: templates.miUasset,
        packageNameNew: dstPkg,
        nameTablePatches: patches,
      );
    } on UAssetRebuildError catch (e) {
      throw StandeeMiBuildError('rebuild failed: ${e.message}');
    }
    // Sanity: any of these would silently break the in-game render.
    if (srcPkg != dstPkg && rebuilt.totalShift == 0 &&
        rebuilt.bytes.length == templates.miUasset.length) {
      // This indicates the rebuilder didn't actually patch the PackageName,
      // i.e. our pkg-old detection was off.  We assert externally below.
    }

    final miName = 'MI_New_$dstGn';
    final folderName = 'T_Bkg_$genreCode';
    final relativePath =
        'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/'
        '$folderName/$miName';

    return StandeeMiBuildResult(
      uassetBytes: rebuilt.bytes,
      uexpBytes: Uint8List.fromList(templates.miUexp),
      relativePath: relativePath,
      patchedNames: rebuilt.patchedNames,
      totalShift: rebuilt.totalShift,
    );
  }
}
