/// Movie genre catalog ported from RR_VHS_Tool.py (lines 1925-1950, 2238-2252).
///
/// The Python source keeps three parallel pieces of metadata per genre — the
/// 3-letter texture code, the background slot count, and the DataTable asset
/// name (which differs from the UI label only for "Kids" → "Kid"). We expose
/// them here as ordered structures so a Dart caller can iterate genres in the
/// canonical order the Python tool uses.
library;

class GenreInfo {
  final String name;
  final String code;
  final int bkgCount;
  final String dataTableName;

  const GenreInfo({
    required this.name,
    required this.code,
    required this.bkgCount,
    required this.dataTableName,
  });
}

const List<GenreInfo> kGenres = [
  GenreInfo(name: 'Action',    code: 'Act', bkgCount: 15, dataTableName: 'Action'),
  GenreInfo(name: 'Adult',     code: 'Adu', bkgCount: 18, dataTableName: 'Adult'),
  GenreInfo(name: 'Adventure', code: 'Adv', bkgCount: 3,  dataTableName: 'Adventure'),
  GenreInfo(name: 'Comedy',    code: 'Com', bkgCount: 12, dataTableName: 'Comedy'),
  GenreInfo(name: 'Drama',     code: 'Dra', bkgCount: 19, dataTableName: 'Drama'),
  GenreInfo(name: 'Fantasy',   code: 'Fan', bkgCount: 11, dataTableName: 'Fantasy'),
  GenreInfo(name: 'Horror',    code: 'Hor', bkgCount: 22, dataTableName: 'Horror'),
  GenreInfo(name: 'Kids',      code: 'Kid', bkgCount: 11, dataTableName: 'Kid'),
  GenreInfo(name: 'Police',    code: 'Pol', bkgCount: 13, dataTableName: 'Police'),
  GenreInfo(name: 'Romance',   code: 'Rom', bkgCount: 14, dataTableName: 'Romance'),
  GenreInfo(name: 'Sci-Fi',    code: 'Sci', bkgCount: 18, dataTableName: 'Sci-Fi'),
  GenreInfo(name: 'Western',   code: 'Wst', bkgCount: 10, dataTableName: 'Western'),
  GenreInfo(name: 'Xmas',      code: 'Xma', bkgCount: 12, dataTableName: 'Xmas'),
];

/// Texture dimensions, DXT1 compressed (RR_VHS_Tool.py:283, 312).
const int kTextureSubWidth = 512;
const int kTextureSubHeight = 512;
const int kTextureBkgWidth = 1024;
const int kTextureBkgHeight = 2048;

/// Slice 1 build version string emitted in the build log.
/// Python tool version is v1.8.2; the Flutter port carries its own line
/// until feature parity (see MIGRATION.md).
const String kFlutterBuildVersion = 'v0.1.0-flutter';

/// Output pak filename. The leading "zzzzzz_" sorts after RetroRewind-Windows.pak
/// so our overrides win at load time (RR_VHS_Tool.py:23-24).
const String kOutputPakFilename = 'zzzzzz_MovieWorkshop_P.pak';

/// Parse a `T_Bkg_<code>_<num>` texture name and return the matching
/// `GenreInfo`, or null if the name doesn't follow that shape or the code
/// isn't a known genre.  Mirrors Python's `parts = name.split('_')` /
/// `genre_code_fb = parts[2]` (RR_VHS_Tool.py:5658-5661).
GenreInfo? parseGenreFromTextureName(String textureName) {
  final parts = textureName.split('_');
  if (parts.length < 4) return null;
  final code = parts[2];
  for (final g in kGenres) {
    if (g.code == code) return g;
  }
  return null;
}
