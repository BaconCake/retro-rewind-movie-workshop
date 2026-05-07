import 'dart:typed_data';

import '../../domain/entities/app_config.dart';
import '../services/pak_cache.dart';

/// Clones the base game's `Standees_Collection_10693` blueprint (Standee B,
/// MI_New_Dra_03) into a per-NR variant.  Pure port of
/// `clone_standee_blueprint` (RR_VHS_Tool.py:4096-4206).
///
/// Unlike the MI and thumbnail templates (which are embedded as binary
/// blobs in the Flutter assets), the Standee mesh blueprint comes from the
/// base game pak.  We extract it via [PakCache] on every build so users
/// always get an up-to-date template if the base game updates.
///
/// The patches are all **same-length**: SKU "10693" → caller's 5-digit
/// SKU, mesh `LA_Standee_B_01` → `LA_Standee_{shape}_01`, MI
/// `MI_New_Dra_03` → `MI_New_{code}_{NN}`, folder `T_Bkg_Dra` →
/// `T_Bkg_{code}`.  No header surgery required.
///
/// The uexp also carries a 4-byte FName-number reference at two locations:
/// the value is `template_sku + 1 = 10694`.  We rewrite both to the
/// caller's `sku + 1` so the in-game thumbnail reference resolves to the
/// per-NR thumbnail texture (built by `StandeeThumbnailBuilder`).

const String _tmplName = 'Standees_Collection_10693';
const String _tmplDir =
    'RetroRewind/Content/VideoStore/asset/prop/Standees/mesh';

const int _tmplSku = 10693;
const int _tmplFnameNum = _tmplSku + 1; // 10694
const String _tmplShape = 'B';
const String _tmplGenreCode = 'Dra';
const int _tmplTexNum = 3;

class StandeeBlueprintCloneResult {
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final String relativePath;
  final int fnameNumReplacements;
  final int skuReplacements;
  final int meshReplacements;
  final int materialReplacements;
  final int folderReplacements;

  const StandeeBlueprintCloneResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.relativePath,
    required this.fnameNumReplacements,
    required this.skuReplacements,
    required this.meshReplacements,
    required this.materialReplacements,
    required this.folderReplacements,
  });
}

class StandeeBlueprintCloneError implements Exception {
  final String code; // E004 / E011
  final String message;
  const StandeeBlueprintCloneError(this.code, this.message);
  @override
  String toString() => '[$code] standee blueprint clone: $message';
}

class StandeeBlueprintCloner {
  final PakCache pakCache;
  StandeeBlueprintCloner(this.pakCache);

  /// Clone the template blueprint.  All inputs are validated for length —
  /// any length mismatch throws because the same-length patch invariant
  /// would otherwise corrupt the asset.
  Future<StandeeBlueprintCloneResult> clone({
    required AppConfig config,
    required int sku,
    required String standeeShape,
    required String genreCode,
    required int texNum,
  }) async {
    final skuStr = sku.toString();
    if (skuStr.length != 5) {
      throw StandeeBlueprintCloneError(
          'E004', 'SKU must be exactly 5 digits, got $sku');
    }
    if (standeeShape.length != _tmplShape.length) {
      throw StandeeBlueprintCloneError(
          'E004', 'shape length mismatch: "$standeeShape"');
    }
    if (genreCode.length != _tmplGenreCode.length) {
      throw StandeeBlueprintCloneError(
          'E004', 'genre code length mismatch: "$genreCode"');
    }
    if (texNum < 1 || texNum > 99) {
      throw StandeeBlueprintCloneError(
          'E004', 'tex_num $texNum out of 2-digit range');
    }

    // Extract base template via PakCache.
    final uaPath = '$_tmplDir/$_tmplName.uasset';
    final uePath = '$_tmplDir/$_tmplName.uexp';
    final uaRes = await pakCache.extractFile(config, uaPath);
    final ueRes = await pakCache.extractFile(config, uePath);
    if (!uaRes.ok || !ueRes.ok) {
      throw StandeeBlueprintCloneError(
          'E011',
          'extract failed: uasset=${uaRes.warning}, uexp=${ueRes.warning}');
    }
    final uaSrc = await pakCache.readFile(config, uaPath);
    final ueSrc = await pakCache.readFile(config, uePath);
    if (uaSrc == null || ueSrc == null) {
      throw const StandeeBlueprintCloneError(
          'E011', 'read failed after extract');
    }

    final ua = Uint8List.fromList(uaSrc);
    final ue = Uint8List.fromList(ueSrc);

    // Patch uexp: FName-number 10694 → sku + 1 (uint32 little endian, two
    // occurrences expected per Python Z. 4151-4154).
    final oldFnum = ByteData(4)..setUint32(0, _tmplFnameNum, Endian.little);
    final newFnum = ByteData(4)..setUint32(0, sku + 1, Endian.little);
    final fnameReps = _replaceAllSameLength(
      ue,
      oldFnum.buffer.asUint8List(),
      newFnum.buffer.asUint8List(),
    );

    // Same-length string replacements in uasset.
    final oldSku = _ascii(_tmplSku.toString());
    final newSku = _ascii(skuStr);
    final oldMesh = _ascii('LA_Standee_${_tmplShape}_01');
    final newMesh = _ascii('LA_Standee_${standeeShape}_01');
    final oldMat = _ascii('MI_New_${_tmplGenreCode}_'
        '${_tmplTexNum.toString().padLeft(2, '0')}');
    final newMat = _ascii(
        'MI_New_${genreCode}_${texNum.toString().padLeft(2, '0')}');
    final oldFolder = _ascii('T_Bkg_$_tmplGenreCode');
    final newFolder = _ascii('T_Bkg_$genreCode');

    final skuReps = _replaceAllSameLength(ua, oldSku, newSku);
    final meshReps = _replaceAllSameLength(ua, oldMesh, newMesh);
    final matReps = _replaceAllSameLength(ua, oldMat, newMat);
    final folderReps = _replaceAllSameLength(ua, oldFolder, newFolder);

    final outName = 'Standees_Collection_$skuStr';
    final relativePath = '$_tmplDir/$outName';

    return StandeeBlueprintCloneResult(
      uassetBytes: ua,
      uexpBytes: ue,
      relativePath: relativePath,
      fnameNumReplacements: fnameReps,
      skuReplacements: skuReps,
      meshReplacements: meshReps,
      materialReplacements: matReps,
      folderReplacements: folderReps,
    );
  }
}

List<int> _ascii(String s) => s.codeUnits;

/// In-place same-length replacement; returns the number of replacements made.
int _replaceAllSameLength(
    Uint8List buf, List<int> needle, List<int> repl) {
  if (needle.length != repl.length) {
    throw ArgumentError('same-length only');
  }
  if (needle.isEmpty) return 0;
  var count = 0;
  final last = buf.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (buf[i + j] != needle[j]) continue outer;
    }
    for (var j = 0; j < repl.length; j++) {
      buf[i + j] = repl[j];
    }
    i += needle.length - 1;
    count++;
  }
  return count;
}
