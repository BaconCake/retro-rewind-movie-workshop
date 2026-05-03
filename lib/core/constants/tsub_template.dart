/// Embedded T_Sub texture templates and the transparent DXT1 pixel
/// generator.  All values are ported verbatim from RR_VHS_Tool.py
/// (lines 1054-1098, 1670-1672) — every byte is load-bearing.
///
/// Subject (T_Sub) textures are 512×512 DXT1 thumbnails the base game
/// renders on top of each VHS cover.  The mod replaces every base T_Sub
/// (T_Sub_01..T_Sub_77) with a fully-transparent version so only the
/// background cover is visible.  Custom slots get a dedicated T_Sub_78+
/// (also transparent) for the same reason.
library;

import 'dart:typed_data';

/// 754-byte uasset template containing the literal name `T_Sub_01`.
/// To clone for a new T_Sub_NN, byte-replace `T_Sub_01` with the new
/// 8-char name (Python: lines 1663-1665).
final Uint8List kTSubSrcUasset = _hexToBytes(_kTSubSrcUassetHex);

/// 144-byte uexp header — the exact PF_DXT1 layout the engine expects.
/// Do NOT use the base game's T_Sub uexp header: it's 148 bytes with
/// `FirstMipToSerialize=-1` markers that yield an unrenderable image
/// (RR_VHS_Tool.py:1642-1644, 371).
final Uint8List kTSubUexpHeader = _hexToBytes(_kTSubUexpHeaderHex);

/// 28-byte mip-dimension metadata appended after the (truncated) pixel
/// area.  Without this exact byte sequence the engine reads SizeX=0 and
/// PixelFormat=PF_Unknown.  RR_VHS_Tool.py:1670.
final Uint8List kTSubMipTail = _hexToBytes(
    'ffffffff000200000002000001000000000000000000000000000000');

/// 4-byte UE4 package magic appended to every uexp.  RR_VHS_Tool.py:1672.
const List<int> kUexpFooter = [0xC1, 0x83, 0x2A, 0x9E];

/// First 8 chars of every T_Sub texture name.  Used both as the embedded
/// template's literal and as the source of the 8-char-length constraint
/// (`T_Sub_<NN>` is 8 chars; `T_Sub_<NNN>` would be 9 and break the
/// fixed-size byte replace).  RR_VHS_Tool.py:1654.
const String kTSubTemplateName = 'T_Sub_01';

/// Number of pixels the uexp pixel area carries before the mip-tail
/// metadata.  Total mip-0 size for a 512×512 DXT1 image = 131,072 bytes
/// (= 128×128 blocks × 8 bytes/block).  The last 28 of those are
/// overwritten by [kTSubMipTail], leaving 131,044 bytes of real DXT1
/// pixel data.  RR_VHS_Tool.py:1671.
const int kTSubPixelBytes = 131072 - 28;

/// First custom T_Sub number reserved for our own custom slots.
/// Slot 1 (first custom) → T_Sub_78, wrapping back to T_Sub_78 after
/// T_Sub_99.  RR_VHS_Tool.py:1048, 1692-1694.
const int kTSubCustomBase = 78;

/// Build a fully-transparent 512×512 DXT1 pixel payload (131,072 bytes).
/// Uses punch-through alpha mode (c0 ≤ c1 → index 3 = transparent black).
/// Each 8-byte block carries `c0=0x0000, c1=0xFFFF, indices=0xFFFFFFFF`.
/// RR_VHS_Tool.py:1054-1062.
Uint8List makeTransparentDxt1Block512() {
  // One DXT1 block, then repeat 128*128 times to fill 512×512.
  final block = Uint8List(8);
  ByteData.sublistView(block)
    ..setUint16(0, 0x0000, Endian.little)
    ..setUint16(2, 0xFFFF, Endian.little)
    ..setUint32(4, 0xFFFFFFFF, Endian.little);
  final out = Uint8List(8 * 128 * 128); // 131,072 bytes
  for (var i = 0; i < 128 * 128; i++) {
    out.setRange(i * 8, i * 8 + 8, block);
  }
  return out;
}

const String _kTSubSrcUassetHex =
    'c1832a9ef8ffffff0000000000000000000000000000000000000000f2020000310000002f47616d652f566964656f53746f72652f61737365742f70726f702f7668732f5375626a6563742f545f5375625f303100002200800a0000000901000000000000ee0100000000000000000000010000004e02000003000000ee010000ae02000000000000000000000000000000000000a83f321849230446b0df4968741d12e501000000010000000a0000000000000000000000000000000000000000000000000000000000000000000000000000004d4f442000000000b20200008203020000000000000000000000000002000000b602000002000000ffffffffffffffffbe020000050000004e6f6e6500f403c50d0800000050465f445854310059f5f9c6310000002f47616d652f566964656f53746f72652f61737365742f70726f702f7668732f5375626a6563742f545f5375625f3031007f97894d140000002f5363726970742f436f7265554f626a65637400f8492d3e0f0000002f5363726970742f456e67696e65008640854906000000436c61737300747778911300000044656661756c745f5f546578747572653244004a680193080000005061636b616765007347881509000000545f5375625f303100084146110a00000054657874757265324400fefd40d103000000000000000500000000000000feffffff090000000000000000000000030000000000000007000000000000000000000004000000000000000000000004000000000000000900000000000000feffffff060000000000000000000000ffffffff00000000fdffffff0000000008000000000000000b0000009000020000000000f202000000000000000000000000000000000000000000000000000001000000010000000000000000000000000000000000000002000000000000000000000000000000fffffffffdffffff0100000001000000000000007800000000000000ffffffffffffffff000002000000000000000200000000000100000048200000';

const String _kTSubUexpHeaderHex =
    '00000000040483020303010008000000080000c81b78ca21e4e043a0befac608ca2d75100000000005000500010000000100000001000000000000004c00020000000000000000000000000000000000000000000002000000020000010000000800000050465f44585431000000000001000000000000000000ffffffffffff0000ffffffffffff0000ffffffffffff';

Uint8List _hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError('hex string length must be even, got ${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
