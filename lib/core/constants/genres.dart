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
  /// Number of base game `T_New_<code>_NN` textures for this genre — the
  /// `"new":` field in Python's GENRES dict (RR_VHS_Tool.py:1937-1949).
  /// 0 means the genre ships no NR textures; the New Release builder still
  /// allows the slot but warns at build time.
  final int newCount;
  final String dataTableName;

  const GenreInfo({
    required this.name,
    required this.code,
    required this.bkgCount,
    required this.newCount,
    required this.dataTableName,
  });
}

const List<GenreInfo> kGenres = [
  GenreInfo(name: 'Action',    code: 'Act', bkgCount: 15, newCount: 3, dataTableName: 'Action'),
  GenreInfo(name: 'Adult',     code: 'Adu', bkgCount: 18, newCount: 0, dataTableName: 'Adult'),
  GenreInfo(name: 'Adventure', code: 'Adv', bkgCount: 3,  newCount: 0, dataTableName: 'Adventure'),
  GenreInfo(name: 'Comedy',    code: 'Com', bkgCount: 12, newCount: 1, dataTableName: 'Comedy'),
  GenreInfo(name: 'Drama',     code: 'Dra', bkgCount: 19, newCount: 3, dataTableName: 'Drama'),
  GenreInfo(name: 'Fantasy',   code: 'Fan', bkgCount: 11, newCount: 2, dataTableName: 'Fantasy'),
  GenreInfo(name: 'Horror',    code: 'Hor', bkgCount: 22, newCount: 4, dataTableName: 'Horror'),
  GenreInfo(name: 'Kids',      code: 'Kid', bkgCount: 11, newCount: 1, dataTableName: 'Kid'),
  GenreInfo(name: 'Police',    code: 'Pol', bkgCount: 13, newCount: 1, dataTableName: 'Police'),
  GenreInfo(name: 'Romance',   code: 'Rom', bkgCount: 14, newCount: 0, dataTableName: 'Romance'),
  GenreInfo(name: 'Sci-Fi',    code: 'Sci', bkgCount: 18, newCount: 4, dataTableName: 'Sci-Fi'),
  GenreInfo(name: 'Western',   code: 'Wst', bkgCount: 10, newCount: 0, dataTableName: 'Western'),
  GenreInfo(name: 'Xmas',      code: 'Xma', bkgCount: 12, newCount: 1, dataTableName: 'Xmas'),
];

/// Texture dimensions, DXT1 compressed (RR_VHS_Tool.py:283, 312).
const int kTextureSubWidth = 512;
const int kTextureSubHeight = 512;
const int kTextureBkgWidth = 1024;
const int kTextureBkgHeight = 2048;

// ── Safe zone / hidden bands (RR_VHS_Tool.py:567-617) ───────────────────
//
// Calibrated against in-game rendering — these define the bands of the
// 1024×2048 background texture that are *not* visible behind the VHS-tape
// model.  Used as a fallback when no layout is selected; for the per-layout
// case, see [layoutVisibleRect] below.
const int kSafeY1 = 35;
const int kSafeW = 993;
const int kSafeH = 2032;
const int kShiftX = 19;
const int kHiddenTop = 35;
const int kHiddenBottom = 448;
const int kHiddenLeft = 34;
const int kHiddenRight = 0;

/// Per-layout visible-window calibration (RR_VHS_Tool.py:609-615).
///
/// `fit_top` is the y-coordinate in the bg texture (1024×2048) where the
/// layout window's top edge sits.  `fit_bottom_hidden` is the number of
/// pixels from the bottom of the texture that are hidden below the layout
/// window's bottom edge.  Window-bottom = [kTextureBkgHeight] − fit_bottom_hidden.
class LayoutFit {
  final int fitTop;
  final int fitBottomHidden;
  const LayoutFit({required this.fitTop, required this.fitBottomHidden});
}

const Map<int, LayoutFit> kLayoutFit = {
  1: LayoutFit(fitTop: 30, fitBottomHidden: 426),
  2: LayoutFit(fitTop: 30, fitBottomHidden: 418),
  3: LayoutFit(fitTop: 31, fitBottomHidden: 417),
  4: LayoutFit(fitTop:  0, fitBottomHidden: 425),
  5: LayoutFit(fitTop: 30, fitBottomHidden: 426),
};

/// Layout-window boundaries inside the 2048×2048 layout BC texture, in
/// **layout pixels** (RR_VHS_Tool.py:621-627).  These are the edges of the
/// black "window" through which the cover art shows on the VHS box.
class LayoutWindow {
  final int top;
  final int bottom;
  final int left;
  final int right;
  const LayoutWindow({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });
}

const Map<int, LayoutWindow> kLayoutWindows = {
  1: LayoutWindow(top:  99, bottom: 1378, left: 113, right: 1353),
  2: LayoutWindow(top: 328, bottom: 1607, left: 113, right:  910),
  3: LayoutWindow(top: 328, bottom: 1607, left: 113, right:  910),
  4: LayoutWindow(top:  47, bottom: 1403, left:  86, right:  938),
  5: LayoutWindow(top:  99, bottom: 1378, left: 113, right: 1292),
};

/// Per-layout overlay nudge (preview-only fine-tuning), in bg-texture
/// pixels (RR_VHS_Tool.py:631-632).  Tuned against in-game screenshots.
const Map<int, int> kLayoutOvlNudgeY = {1: 0, 2: 0, 3: 0, 4: 0, 5: 0};
const Map<int, int> kLayoutOvlNudgeX = {1: -3, 2: -3, 3: -3, 4: 0, 5: -3};

/// Visible rectangle in bg-texture coordinates (top, bottom, left, right)
/// for a given layout (1..5).  Returns null for invalid layouts.
///
/// Pure port of `get_layout_visible_rect()` (RR_VHS_Tool.py:634-665) —
/// tested for parity in `test/layout_visible_rect_test.dart`.
class LayoutVisibleRect {
  final double top;
  final double bottom;
  final double left;
  final double right;
  const LayoutVisibleRect({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });
}

LayoutVisibleRect? layoutVisibleRect(int layoutN) {
  if (layoutN < 1 || layoutN > 5) return null;
  final lf = kLayoutFit[layoutN]!;
  final lw = kLayoutWindows[layoutN]!;
  final bgTop = lf.fitTop.toDouble();
  final bgBot = (kTextureBkgHeight - lf.fitBottomHidden).toDouble();
  final lscale = (bgBot - bgTop) / (lw.bottom - lw.top);
  var loy = bgTop - lw.top * lscale + (kLayoutOvlNudgeY[layoutN] ?? 0);

  // Horizontal alignment: layout 4 aligns left at x=0, others at kHiddenLeft.
  // Non-wide layouts right-align to kTextureBkgWidth.
  final windowW = (lw.right - lw.left) * lscale;
  double lox;
  if (windowW > kTextureBkgWidth) {
    final leftAlign = (layoutN == 4) ? 0 : kHiddenLeft;
    lox = leftAlign - lw.left * lscale;
  } else {
    lox = kTextureBkgWidth - lw.right * lscale;
  }
  lox += (kLayoutOvlNudgeX[layoutN] ?? 0);

  // Window edges in bg-texture coords, clamped to texture bounds.
  var visTop = loy + lw.top * lscale;
  var visBot = loy + lw.bottom * lscale;
  var visLeft = lox + lw.left * lscale;
  var visRight = lox + lw.right * lscale;
  visLeft = visLeft.clamp(0, kTextureBkgWidth).toDouble();
  visRight = visRight.clamp(0, kTextureBkgWidth).toDouble();
  visTop = visTop.clamp(0, kTextureBkgHeight).toDouble();
  visBot = visBot.clamp(0, kTextureBkgHeight).toDouble();

  return LayoutVisibleRect(
    top: visTop,
    bottom: visBot,
    left: visLeft,
    right: visRight,
  );
}

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
