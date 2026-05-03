import 'dart:typed_data';

import '../../core/constants/tsub_template.dart';

/// Bytes of one transparent T_Sub texture, ready to write to disk.
class TSubArtifacts {
  final Uint8List uasset;
  final Uint8List uexp;
  const TSubArtifacts({required this.uasset, required this.uexp});
}

/// Build the (uasset, uexp) pair for a single transparent T_Sub texture.
/// Mirrors `build_transparent_tsub` in RR_VHS_Tool.py:1620-1679.
///
/// [name] must be an 8-char `T_Sub_NN` string.  Anything else (e.g. the
/// 9-char `T_Sub_100`) silently falls back to `T_Sub_78` because the
/// embedded uasset template is built around a fixed 8-char name and a
/// length-changing replace would shift every offset in the file.  Python
/// does the same fall-back (lines 1656-1661).
class TransparentTSubBuilder {
  const TransparentTSubBuilder();

  /// Build artifacts for [name].  Pure / no IO.
  TSubArtifacts build(String name) {
    final dstName = name.length == kTSubTemplateName.length ? name : 'T_Sub_78';

    // uasset: byte-for-byte replace `T_Sub_01` with the new 8-char name.
    // Both strings are ASCII-only and identical length so the file layout
    // (offsets, sizes, the trailing serial_size field) stays valid.
    final src = kTSubTemplateName.codeUnits;
    final dst = dstName.codeUnits;
    final uasset = Uint8List.fromList(kTSubSrcUasset);
    _replaceAllBytes(uasset, src, dst);

    // uexp: header + transparent pixels (truncated to make room for the
    // 28-byte mip-tail metadata) + mip tail + 4-byte package magic.
    final pixels = makeTransparentDxt1Block512();
    final uexpLen = kTSubUexpHeader.length +
        kTSubPixelBytes +
        kTSubMipTail.length +
        kUexpFooter.length;
    final uexp = Uint8List(uexpLen);
    var off = 0;
    uexp.setRange(off, off + kTSubUexpHeader.length, kTSubUexpHeader);
    off += kTSubUexpHeader.length;
    uexp.setRange(off, off + kTSubPixelBytes, pixels);
    off += kTSubPixelBytes;
    uexp.setRange(off, off + kTSubMipTail.length, kTSubMipTail);
    off += kTSubMipTail.length;
    uexp.setRange(off, off + kUexpFooter.length, kUexpFooter);

    return TSubArtifacts(uasset: uasset, uexp: uexp);
  }

  /// Map a 1-based custom-slot index to its dedicated T_Sub name, wrapping
  /// at the T_Sub_78..T_Sub_99 range.  Mirrors `get_custom_slot_si`
  /// (RR_VHS_Tool.py:1683-1694).  All custom T_Subs are identical
  /// transparent images, so sharing across slots is safe.
  static String customSlotTSubName(int slotIndex1Based) {
    const range = 99 - kTSubCustomBase + 1; // 22 names, 78..99
    final n = kTSubCustomBase + ((slotIndex1Based - 1) % range);
    return 'T_Sub_${n.toString().padLeft(2, '0')}';
  }

  /// All `T_Sub_01`..`T_Sub_77` names — always emitted regardless of user
  /// configuration so the base game's procedural subject art is suppressed
  /// across the whole video store.  RR_VHS_Tool.py:14037.
  static List<String> baseTSubNames() {
    return [
      for (var i = 1; i <= 77; i++) 'T_Sub_${i.toString().padLeft(2, '0')}',
    ];
  }

  static void _replaceAllBytes(
      Uint8List buf, List<int> needle, List<int> replacement) {
    if (needle.length != replacement.length) {
      throw ArgumentError(
          'replacement must be the same length as the needle '
          '(needle=${needle.length}, replacement=${replacement.length})');
    }
    if (needle.isEmpty) return;
    var i = 0;
    while (i + needle.length <= buf.length) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (buf[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        buf.setRange(i, i + replacement.length, replacement);
        i += needle.length;
      } else {
        i++;
      }
    }
  }
}
