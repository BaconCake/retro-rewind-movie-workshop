import 'dart:convert';
import 'dart:typed_data';

import 'datatable_file.dart';
import 'slot_data.dart';

/// Decodes the row block of a base-game `.uexp` back into [SlotData] entries.
/// Mirrors `CleanDataTableBuilder.read_slot_data` (RR_VHS_Tool.py:3182-3299).
///
/// The base game stores **77 rows per slot** (one per T_Sub texture variant)
/// with otherwise identical metadata. We dedupe by `bkgTex` and skip every
/// row whose SubjectImage is not `T_Sub_01`, so the result is one
/// [SlotData] per real slot.
///
/// We walk by `uexp.rowSize` until SI/BI validation fails, *not* until
/// `rowCount` rows have been read — Action's base-game header overstates
/// rowCount by several rows and the walker has to bail when the structure
/// breaks.
class RowDecoder {
  /// Decode every visible slot from [uexp]. Skips bridge/sentinel rows
  /// (SI != "T_Sub_01") and rows whose `bkgTex` was already emitted.
  static List<SlotData> decodeBaseSlots(UExp uexp, NameTable names) {
    final ue = uexp.rawBytes;
    final view = ByteData.sublistView(ue);
    final out = <SlotData>[];
    final seen = <String>{};

    final tailOffsets = _tailOffsetsFor(uexp.schema);
    var pos = uexp.rowStart;

    // Walk until a row's SI/BI fields stop validating — that's the boundary
    // between real rows and the trailer.
    while (pos + 20 <= ue.length) {
      final pnIdx = view.getInt32(pos + 8, Endian.little);
      final siLen = view.getInt32(pos + 16, Endian.little);
      if (siLen < 7 || siLen > 12) break;

      final biOff = pos + 20 + siLen;
      if (biOff + 4 > ue.length) break;
      final biLen = view.getInt32(biOff, Endian.little);
      if (biLen < 8 || biLen > 20) break;

      final bkgStart = biOff + 4;
      final bkgEnd = bkgStart + biLen;
      if (bkgEnd > ue.length) break;

      final bkgRaw = ue.sublist(bkgStart, bkgEnd - 1);
      final bkg = utf8.decode(bkgRaw, allowMalformed: true);
      if (!bkg.startsWith('T_Bkg_')) break;

      final siRaw = ue.sublist(pos + 20, pos + 20 + siLen - 1);
      final si = utf8.decode(siRaw, allowMalformed: true);

      if (si == 'T_Sub_01' && !seen.contains(bkg)) {
        if (bkgEnd + tailOffsets.minTailExtent <= ue.length) {
          final ls = view.getInt32(bkgEnd + tailOffsets.lsOff, Endian.little);
          final lsc =
              view.getInt32(bkgEnd + tailOffsets.lscOff, Endian.little);
          final sku =
              view.getInt32(bkgEnd + tailOffsets.skuOff, Endian.little);
          final pn = (pnIdx >= 0 && pnIdx < names.entries.length)
              ? names.entries[pnIdx].value
              : '';
          out.add(SlotData(
            bkgTex: bkg,
            pnName: pn,
            ls: ls,
            lsc: lsc,
            sku: sku,
            ntu: false,
          ));
          seen.add(bkg);
        }
      }
      pos += uexp.rowSize;
    }
    return out;
  }
}

class _TailOffsets {
  final int lsOff;
  final int lscOff;
  final int skuOff;
  final int minTailExtent; // bytes after bkgEnd we need to read up to skuOff+4
  const _TailOffsets(this.lsOff, this.lscOff, this.skuOff, this.minTailExtent);
}

_TailOffsets _tailOffsetsFor(RowSchema s) {
  switch (s) {
    case RowSchema.v1:
      return const _TailOffsets(9, 13, 17, 21);
    case RowSchema.v2:
      return const _TailOffsets(10, 14, 18, 22);
    case RowSchema.v3:
      return const _TailOffsets(10, 14, 19, 23); // CP at +18 shifts SKU to +19
  }
}
