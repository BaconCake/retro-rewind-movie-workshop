import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// Loader + metadata for the binary templates the standee asset builders
/// patch in place.  The blobs themselves were extracted from
/// `RR_VHS_Tool.py`'s `_..._B64Z` constants by `scripts/extract_standee_templates.py`
/// and shipped under `assets/standee_templates/`.
///
/// Decompressed sizes (asserted by Python at RR_VHS_Tool.py:1171-1172):
///   * mi_uasset.bin            — 1772 bytes
///   * mi_uexp.bin              — 33471 bytes
///   * thumb_uasset.bin         — 813 bytes
///   * thumb_uexp_header.bin    — 117 bytes
///   * standee_{a,b,c}.jpg      — fullres standee preview JPEGs
class StandeeTemplates {
  /// Cached after first load; null until [load] completes once.
  static StandeeTemplates? _cached;

  final Uint8List miUasset;
  final Uint8List miUexp;
  final Uint8List thumbUasset;
  final Uint8List thumbUexpHeader;
  final Uint8List standeeFullresA;
  final Uint8List standeeFullresB;
  final Uint8List standeeFullresC;

  const StandeeTemplates._({
    required this.miUasset,
    required this.miUexp,
    required this.thumbUasset,
    required this.thumbUexpHeader,
    required this.standeeFullresA,
    required this.standeeFullresB,
    required this.standeeFullresC,
  });

  /// Load all templates from rootBundle.  Idempotent — repeat calls return
  /// the cached instance.  Tests can construct an instance directly via
  /// [StandeeTemplates.fromBytes] to avoid touching the asset bundle.
  static Future<StandeeTemplates> load() async {
    if (_cached != null) return _cached!;
    Future<Uint8List> read(String name) async {
      final bd = await rootBundle.load('assets/standee_templates/$name');
      return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    }

    _cached = StandeeTemplates._(
      miUasset: await read('mi_uasset.bin'),
      miUexp: await read('mi_uexp.bin'),
      thumbUasset: await read('thumb_uasset.bin'),
      thumbUexpHeader: await read('thumb_uexp_header.bin'),
      standeeFullresA: await read('standee_a.jpg'),
      standeeFullresB: await read('standee_b.jpg'),
      standeeFullresC: await read('standee_c.jpg'),
    );
    return _cached!;
  }

  /// Test-only constructor that bypasses rootBundle.
  factory StandeeTemplates.fromBytes({
    required Uint8List miUasset,
    required Uint8List miUexp,
    required Uint8List thumbUasset,
    required Uint8List thumbUexpHeader,
    required Uint8List standeeFullresA,
    required Uint8List standeeFullresB,
    required Uint8List standeeFullresC,
  }) {
    return StandeeTemplates._(
      miUasset: miUasset,
      miUexp: miUexp,
      thumbUasset: thumbUasset,
      thumbUexpHeader: thumbUexpHeader,
      standeeFullresA: standeeFullresA,
      standeeFullresB: standeeFullresB,
      standeeFullresC: standeeFullresC,
    );
  }

  /// Pick the fullres JPEG for [shape] ("A", "B", or "C").  Throws on
  /// unknown shapes — same behavior as Python's `fullres_b64z[shape]`
  /// dict lookup at Z. 3971-3975.
  Uint8List fullresFor(String shape) {
    switch (shape) {
      case 'A':
        return standeeFullresA;
      case 'B':
        return standeeFullresB;
      case 'C':
        return standeeFullresC;
    }
    throw ArgumentError('Unknown standee shape: $shape');
  }
}

// ── MI template metadata (RR_VHS_Tool.py:1632-1634) ───────────────────────
//
// The MI uasset template was generated from MI_New_Hor_04 with Standee A.
// All replacements are same-length (3-char genre, 2-char num, 1-char shape),
// so no offset adjustments are needed.

const String kMiTemplateGenre = 'Hor';
const int kMiTemplateNum = 4;
const String kMiTemplateShape = 'A';

// ── Thumbnail-texture metadata (RR_VHS_Tool.py:1189-1193) ─────────────────

const int kThumbTexTemplateSku = 12286;
const int kThumbTexTemplateFnameNum = 12287;
const int kThumbTexFnameNumOffset = 0x29D;
const int kThumbTexPixelSize = 262144;

/// 28-byte uexp footer the thumbnail texture asset needs after the
/// pixel data — Python `_THUMB_TEX_TRAILING`, RR_VHS_Tool.py:1193.
final Uint8List kThumbTexTrailing = Uint8List.fromList([
  0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0xC1, 0x83, 0x2A, 0x9E,
]);
