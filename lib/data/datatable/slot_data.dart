/// One row's worth of movie metadata. Mirrors the per-slot dict shape from
/// Python's `CLEAN_DT_SLOT_DATA[<genre>]` (RR_VHS_Tool.py:~2300+, e.g.
/// `HORROR_SLOT_DATA`).
///
/// `bkgTex` is the Background-image texture name (e.g. `"T_Bkg_Hor_01"` for
/// a base-game slot, `"T_Bkg_Hor_001"` for a custom slot — the trailing
/// digit count is significant: 2 vs 3 digits maps to BI FString length 13
/// vs 14 in the synthesised row).
///
/// `ls`, `lsc`, `sku` are the in-row int32 fields. `ls == 0` is treated by
/// the row synthesiser as "pick a random integer in [1, 5]" — matching the
/// Python builder which does the same.
///
/// **NB**: [isNewToUnlock] (JSON key `"ntu"`) is *not* the user-facing
/// "Old tape" tag.  Old/Holo are derived from the SKU itself (see
/// `skuIsOld` / `skuIsHolo` in `lib/domain/sku.dart`), not from this
/// field.  `NewToUnlock` is declared in Film_DataStructure but never
/// serialized into cooked base-game DataTables (Python parity note at
/// RR_VHS_Tool.py:113-114), so the value persists round-trip with
/// Python but doesn't reach the built pak for genre slots.  NR slots
/// set the NewToUnlock byte unconditionally in the binary builder.
class SlotData {
  final String bkgTex;
  final String pnName;
  final int ls;
  final int lsc;
  final int sku;

  /// Persistence-only field for Python compatibility.  See class-level
  /// docs — this is **not** the Old-Tag.  Defaults to false; flipping it
  /// has no observable effect on the built pak.
  final bool isNewToUnlock;

  /// Custom T_Sub texture name for this slot (e.g. `"T_Sub_78"`).  Null when
  /// the slot reuses the row-synthesizer's hard-coded `T_Sub_01` (the safe
  /// universal value — every base T_Sub is replaced with a transparent
  /// version, so any T_Sub_NN < 78 reads identically transparent in-game).
  /// Custom slots use T_Sub_78+ to avoid interfering with base-game uses.
  /// RR_VHS_Tool.py:1044-1047, 1683-1694.
  final String? subTex;

  const SlotData({
    required this.bkgTex,
    required this.pnName,
    required this.ls,
    required this.lsc,
    required this.sku,
    this.isNewToUnlock = false,
    this.subTex,
  });

  SlotData copyWith({
    String? bkgTex,
    String? pnName,
    int? ls,
    int? lsc,
    int? sku,
    bool? isNewToUnlock,
    String? subTex,
  }) {
    return SlotData(
      bkgTex: bkgTex ?? this.bkgTex,
      pnName: pnName ?? this.pnName,
      ls: ls ?? this.ls,
      lsc: lsc ?? this.lsc,
      sku: sku ?? this.sku,
      isNewToUnlock: isNewToUnlock ?? this.isNewToUnlock,
      subTex: subTex ?? this.subTex,
    );
  }

  /// JSON shape consumed by `custom_slots.json` — same key set the Python
  /// tool reads/writes (RR_VHS_Tool.py:556-580).  Wire key stays `"ntu"`
  /// to keep the file format binary-compatible with the Python tool.
  /// `sub_tex` is omitted when null so we don't pollute hand-edited files
  /// with explicit `null`s.
  Map<String, Object> toJson() {
    return {
      'bkg_tex': bkgTex,
      'sub_tex': ?subTex,
      'pn_name': pnName,
      'ls': ls,
      'lsc': lsc,
      'sku': sku,
      'ntu': isNewToUnlock,
    };
  }
}
