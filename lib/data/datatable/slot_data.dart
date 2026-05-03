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
class SlotData {
  final String bkgTex;
  final String pnName;
  final int ls;
  final int lsc;
  final int sku;
  final bool ntu;

  const SlotData({
    required this.bkgTex,
    required this.pnName,
    required this.ls,
    required this.lsc,
    required this.sku,
    this.ntu = false,
  });
}
