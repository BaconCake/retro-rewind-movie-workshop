import 'dart:typed_data';

import '../../domain/entities/app_config.dart';
import '../services/pak_cache.dart';
import '../services/uasset_rebuilder.dart';

/// Clones the base game's `Standees_Collection_10693` blueprint (Standee B,
/// MI_New_Dra_03) into a per-NR variant.  Pure port of
/// `clone_standee_blueprint` (RR_VHS_Tool.py:4573-4681).
///
/// Unlike the MI and thumbnail templates (which are embedded as binary
/// blobs in the Flutter assets), the Standee mesh blueprint comes from the
/// base game pak.  We extract it via [PakCache] on every build so users
/// always get an up-to-date template if the base game updates.
///
/// uexp patches stay length-preserving: the FName-number 10694 → sku+1
/// (uint32 little-endian) at two locations, so a same-length in-place
/// replace covers it.
///
/// uasset patches go through [rebuildUAssetWithNamePatches] because as of
/// v1.8.2 the material reference grew from `MI_New_Dra_03` (12 chars) to
/// `MI_New_<code>_<NN:03d>` (13 chars) — one byte per occurrence — and a
/// length-preserving in-place replace would corrupt the asset.

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
  /// Number of FName-number occurrences patched in the uexp (always 2 in
  /// practice — Python prints this for diagnostic logs).
  final int fnameNumReplacements;
  /// Number of name-table entries that had at least one substring patch
  /// applied during the uasset rebuild.
  final int patchedNames;
  /// `newLen - oldLen` for the rebuilt uasset (positive — the 3-digit MI
  /// reference grows the file by 1 byte per occurrence).
  final int totalShift;

  const StandeeBlueprintCloneResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.relativePath,
    required this.fnameNumReplacements,
    required this.patchedNames,
    required this.totalShift,
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
  /// any length mismatch on the same-length axes (SKU 5 digits, shape 1
  /// char, genre code 3 chars) throws because patches that need same-
  /// length input would otherwise silently corrupt the asset.  texNum is
  /// capped at 99 (3-digit padding).
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
          'E004', 'tex_num $texNum out of 3-digit range (1..99)');
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

    // ── uexp: same-length FName-number patch ────────────────────────────
    final ue = Uint8List.fromList(ueSrc);
    final oldFnum = ByteData(4)..setUint32(0, _tmplFnameNum, Endian.little);
    final newFnum = ByteData(4)..setUint32(0, sku + 1, Endian.little);
    final fnameReps = _replaceAllSameLength(
      ue,
      oldFnum.buffer.asUint8List(),
      newFnum.buffer.asUint8List(),
    );

    // ── uasset: length-changing rebuild via the new helper ─────────────
    // Patches list mirrors Python (RR_VHS_Tool.py:4646-4654).  The MI
    // reference is the only length-changing one; the others happen to be
    // same-length but we send them through the same rebuilder so they're
    // applied in a single name-table walk.
    final patches = <NameTablePatch>[];
    if (skuStr != _tmplSku.toString()) {
      patches.add(NameTablePatch(_tmplSku.toString(), skuStr));
    }
    if (standeeShape != _tmplShape) {
      patches.add(NameTablePatch(
          'LA_Standee_$_tmplShape', 'LA_Standee_$standeeShape'));
    }
    final srcMat =
        'MI_New_${_tmplGenreCode}_${_tmplTexNum.toString().padLeft(2, '0')}';
    final dstMat =
        'MI_New_${genreCode}_${texNum.toString().padLeft(3, '0')}';
    if (srcMat != dstMat) {
      patches.add(NameTablePatch(srcMat, dstMat));
    }
    if (genreCode != _tmplGenreCode) {
      patches.add(NameTablePatch(
          'T_Bkg_$_tmplGenreCode', 'T_Bkg_$genreCode'));
    }

    final srcPkg = '/Game/VideoStore/asset/prop/Standees/mesh/$_tmplName';
    final dstPkg =
        '/Game/VideoStore/asset/prop/Standees/mesh/Standees_Collection_$skuStr';

    final UAssetRebuildResult rebuilt;
    try {
      rebuilt = rebuildUAssetWithNamePatches(
        data: Uint8List.fromList(uaSrc),
        packageNameNew: dstPkg,
        nameTablePatches: patches,
      );
    } on UAssetRebuildError catch (e) {
      throw StandeeBlueprintCloneError(
          'E004', 'uasset rebuild failed: ${e.message}');
    }
    // Static analyzer needs srcPkg to be referenced — keeps doc-string
    // accurate against Python (the rebuilder uses dstPkg directly).
    assert(srcPkg.isNotEmpty);

    final outName = 'Standees_Collection_$skuStr';
    final relativePath = '$_tmplDir/$outName';

    return StandeeBlueprintCloneResult(
      uassetBytes: rebuilt.bytes,
      uexpBytes: ue,
      relativePath: relativePath,
      fnameNumReplacements: fnameReps,
      patchedNames: rebuilt.patchedNames,
      totalShift: rebuilt.totalShift,
    );
  }
}

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
