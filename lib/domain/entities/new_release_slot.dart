/// One New Release slot — the persisted record for a custom NR movie.
///
/// JSON shape matches Python's `NR_SLOT_DATA` entry (RR_VHS_Tool.py Z. 2131-2141)
/// so users can switch between the Python tool and the Flutter port without
/// losing their `nr_custom_slots.json`.
///
/// Fields:
/// - [title] — display name shown on the in-game New Releases shelf.
/// - [genre] — full genre name (e.g. "Drama"), key into `kNrGenreByte`.
/// - [genreCode] — 3-letter code (e.g. "Dra") used in [bkgTex].
/// - [genreByte] — DataTable row genre byte; auto-fixed on load if the
///   constants table was corrected after this slot was saved.
/// - [bkgTex] — 12-char texture name `T_New_<code>_<NN>`, exact length
///   required by the DataTable row layout.
/// - [sku] — 5-digit unique ID in 50000..59999.
/// - [standeeShape] — "A", "B", or "C".
/// - [texNum] — base-game texture slot index (1..base_new_count for the
///   genre).  Multiple NRs may share the same [texNum] when a genre has
///   more NRs than base T_New textures; SKUs/titles/standees still differ.
/// - [createdAt] / [lastEditedAt] — ISO-8601 UTC, used by the sort UI.
class NewReleaseSlot {
  final String title;
  final String genre;
  final String genreCode;
  final int genreByte;
  final String bkgTex;
  final int sku;
  final String standeeShape;
  final int texNum;
  final String? createdAt;
  final String? lastEditedAt;

  const NewReleaseSlot({
    required this.title,
    required this.genre,
    required this.genreCode,
    required this.genreByte,
    required this.bkgTex,
    required this.sku,
    required this.standeeShape,
    required this.texNum,
    this.createdAt,
    this.lastEditedAt,
  });

  NewReleaseSlot copyWith({
    String? title,
    String? genre,
    String? genreCode,
    int? genreByte,
    String? bkgTex,
    int? sku,
    String? standeeShape,
    int? texNum,
    String? createdAt,
    String? lastEditedAt,
  }) {
    return NewReleaseSlot(
      title: title ?? this.title,
      genre: genre ?? this.genre,
      genreCode: genreCode ?? this.genreCode,
      genreByte: genreByte ?? this.genreByte,
      bkgTex: bkgTex ?? this.bkgTex,
      sku: sku ?? this.sku,
      standeeShape: standeeShape ?? this.standeeShape,
      texNum: texNum ?? this.texNum,
      createdAt: createdAt ?? this.createdAt,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'genre': genre,
        'genre_code': genreCode,
        'genre_byte': genreByte,
        'bkg_tex': bkgTex,
        'sku': sku,
        'standee_shape': standeeShape,
        'tex_num': texNum,
        if (createdAt != null) 'created_at': createdAt,
        if (lastEditedAt != null) 'last_edited_at': lastEditedAt,
      };

  /// Tolerant parser: returns null on missing-or-wrong-type required fields.
  /// Mirrors Python's silent skip of malformed entries on load.
  static NewReleaseSlot? fromJson(Map<dynamic, dynamic> m) {
    final title = m['title'];
    final genre = m['genre'];
    final genreCode = m['genre_code'];
    final genreByte = m['genre_byte'];
    final bkgTex = m['bkg_tex'];
    final sku = m['sku'];
    final standeeShape = m['standee_shape'];
    final texNum = m['tex_num'];
    if (title is! String) return null;
    if (genre is! String) return null;
    if (genreCode is! String) return null;
    if (genreByte is! num) return null;
    if (bkgTex is! String || bkgTex.isEmpty) return null;
    if (sku is! num) return null;
    if (standeeShape is! String) return null;
    if (texNum is! num) return null;
    return NewReleaseSlot(
      title: title,
      genre: genre,
      genreCode: genreCode,
      genreByte: genreByte.toInt(),
      bkgTex: bkgTex,
      sku: sku.toInt(),
      standeeShape: standeeShape,
      texNum: texNum.toInt(),
      createdAt: m['created_at'] is String ? m['created_at'] as String : null,
      lastEditedAt:
          m['last_edited_at'] is String ? m['last_edited_at'] as String : null,
    );
  }
}
