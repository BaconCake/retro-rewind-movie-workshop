import 'dart:convert';
import 'dart:typed_data';

import 'standee_templates.dart';

/// Material-instance builder for a New Release standee.
///
/// Pure port of `create_mi_for_nr` (RR_VHS_Tool.py:4035-4094): clones the
/// embedded `MI_New_Hor_04` template (Standee A) and applies three
/// **same-length** byte replacements to retarget it at the caller's genre,
/// texture slot, and standee shape.  Length-matching keeps every offset
/// inside the asset stable, so no header surgery is needed.
///
/// Output asset names follow Python's pattern:
///
///   `RetroRewind/Content/VideoStore/asset/prop/vhs/Background/T_Bkg_{genre}/MI_New_{genre}_{NN}.uasset`
///
/// Caller (PakBuilder, slice 5d) is responsible for placing the bytes at the
/// right path inside the build root and emitting the shared uexp.

class StandeeMiBuildResult {
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final String relativePath;
  final int genreNumReplacements;
  final int folderReplacements;
  final int aoReplacements;

  const StandeeMiBuildResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.relativePath,
    required this.genreNumReplacements,
    required this.folderReplacements,
    required this.aoReplacements,
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
  /// [texNum] — slot number (1..base_new_count for the genre).  Encoded as
  /// 2-digit zero-padded → mismatched length to the template's "04" would
  /// throw here (but tex_num always fits 2 digits since `kNrPerGenreCap=99`).
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
          'tex_num $texNum out of range — must fit 2 digits');
    }
    if (standeeShape.length != kMiTemplateShape.length) {
      throw StandeeMiBuildError(
          'standee shape length mismatch: got "$standeeShape"');
    }

    final oldGn = utf8.encode('${kMiTemplateGenre}_'
        '${kMiTemplateNum.toString().padLeft(2, '0')}');
    final newGn = utf8.encode(
        '${genreCode}_${texNum.toString().padLeft(2, '0')}');
    final oldFolder = utf8.encode('T_Bkg_$kMiTemplateGenre');
    final newFolder = utf8.encode('T_Bkg_$genreCode');
    final oldAo = utf8.encode('T_Standee_${kMiTemplateShape}_01_ao');
    final newAo = utf8.encode('T_Standee_${standeeShape}_01_ao');

    final n1 = countOccurrences(templates.miUasset, oldGn);
    final n2 = countOccurrences(templates.miUasset, oldFolder);
    final n3 = countOccurrences(templates.miUasset, oldAo);

    var data = Uint8List.fromList(templates.miUasset);
    data = replaceAllSameLength(data, oldGn, newGn);
    data = replaceAllSameLength(data, oldFolder, newFolder);
    data = replaceAllSameLength(data, oldAo, newAo);

    final miName = 'MI_New_${genreCode}_${texNum.toString().padLeft(2, '0')}';
    final folderName = 'T_Bkg_$genreCode';
    final relativePath =
        'RetroRewind/Content/VideoStore/asset/prop/vhs/Background/'
        '$folderName/$miName';

    return StandeeMiBuildResult(
      uassetBytes: data,
      uexpBytes: Uint8List.fromList(templates.miUexp),
      relativePath: relativePath,
      genreNumReplacements: n1,
      folderReplacements: n2,
      aoReplacements: n3,
    );
  }
}

/// Replace every occurrence of [needle] in [source] with [replacement] in
/// place.  Both byte sequences must be the same length — caller is expected
/// to guarantee that.  Returns a new Uint8List; the input is left untouched.
Uint8List replaceAllSameLength(
    Uint8List source, List<int> needle, List<int> replacement) {
  if (needle.length != replacement.length) {
    throw ArgumentError(
        'replaceAllSameLength: needle.length=${needle.length} '
        '!= replacement.length=${replacement.length}');
  }
  if (needle.isEmpty) return source;
  final out = Uint8List.fromList(source);
  final last = out.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (out[i + j] != needle[j]) continue outer;
    }
    for (var j = 0; j < replacement.length; j++) {
      out[i + j] = replacement[j];
    }
    i += needle.length - 1; // skip past the replaced region
  }
  return out;
}

/// Count occurrences of [needle] in [source] (non-overlapping).  Useful for
/// the debug/log output Python emits when patching standee assets.
int countOccurrences(Uint8List source, List<int> needle) {
  if (needle.isEmpty || needle.length > source.length) return 0;
  var count = 0;
  final last = source.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (source[i + j] != needle[j]) continue outer;
    }
    count++;
    i += needle.length - 1;
  }
  return count;
}
