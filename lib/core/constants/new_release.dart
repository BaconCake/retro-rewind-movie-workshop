/// New Release system constants — port of RR_VHS_Tool.py Z. 1985-2003.
///
/// New Releases use the `NewRelease_Details_-_Data` DataTable and the base
/// game's `T_New_<code>_NN` background textures.  Only a subset of genres
/// have base game T_New textures, so [kNrGenreByte] is the authoritative
/// "is this genre NR-eligible" check.
library;

/// Genre byte values for NewRelease_Details DataTable rows (binary offset 40
/// in the 54-byte row).  Confirmed from base game genre DataTable binary
/// analysis — see Python comment block at Z. 1987-1997.
///
/// Adult (0x10) is intentionally excluded: game logic blocks Adult New
/// Releases from appearing in-game, so we don't expose them in the UI.
const Map<String, int> kNrGenreByte = {
  'Action':  0x01,
  'Comedy':  0x03,
  'Drama':   0x04,
  'Horror':  0x05,
  'Sci-Fi':  0x06,
  'Fantasy': 0x07,
  'Kids':    0x0C,
  'Police':  0x0E,
  'Xmas':    0x12,
  // Genres without base game T_New textures (Romance, Western) are still
  // included — Python keeps them so the DataTable builder can warn when a
  // user tries to ship one.  Build-time filter at Python Z. 3838-3845.
  'Romance': 0x0A,
  'Western': 0x11,
};

/// Genres that support New Releases, in the same iteration order as
/// [kNrGenreByte] (insertion order is preserved for `Map` literals in Dart).
List<String> get kNrGenres => kNrGenreByte.keys.toList(growable: false);

/// Standee shapes available for New Releases.  Each maps to a different
/// in-game standee mesh (`LA_Standee_<shape>_01`) — Python Z. 2003.
const List<String> kNrStandeeShapes = ['A', 'B', 'C'];

/// Soft cap of 99 NRs per genre.  Above this, the bkg_tex format
/// `T_New_<code>_<NN>` widens from 12 to 13 chars (e.g. `T_New_Dra_100`),
/// changing the BackgroundImage FString length in the DataTable row by 1
/// byte and breaking the fixed 54-byte row layout.  3-digit support is
/// feasible but parked — Python Z. 2077-2083.
const int kNrPerGenreCap = 99;

/// SKU range for New Releases — Python Z. 2127.  Distinct from base-game
/// SKUs (which use other ranges per genre) so NR slots don't collide with
/// existing movies.
const int kNrSkuMin = 50000;
const int kNrSkuMax = 59999;

/// Number of base-game 2-digit `T_New_<code>_<NN>` textures shipped per
/// genre.  Pure port of `GENRES["new"]` (RR_VHS_Tool.py:1937).
///
/// Drives the Legacy 2-digit Co-Inject path (v1.8.2.1 / v1.8.2.2):
///   * `tex_num <= count` → extract the donor 2-digit asset from the base
///     pak via [PakCache.prepareNrLegacy2digit] and inject the user cover
///     into both 3-digit and 2-digit slots.
///   * `tex_num > count` → out-of-range; v1.8.2.2 will synthesize the
///     missing 2-digit asset by length-preserving clone of `T_New_Hor_01`.
///
/// Matches [kNrGenreByte] keys exactly: every NR-eligible genre has an
/// entry here (Romance/Western are 0 because their NRs are warning-only,
/// they have no base T_New textures to either extract or be cloned into).
const Map<String, int> kBaseNewSlotCount = {
  'Action':  3,
  'Comedy':  1,
  'Drama':   3,
  'Fantasy': 2,
  'Horror':  4,
  'Kids':    1,
  'Police':  1,
  'Sci-Fi':  4,
  'Xmas':    1,
  'Romance': 0,
  'Western': 0,
};
