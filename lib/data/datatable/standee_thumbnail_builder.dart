import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart';
import 'standee_templates.dart';

/// Thumbnail-texture builder for the in-game computer's standee collection.
///
/// Pure port of `create_standee_thumbnail` (RR_VHS_Tool.py:3932-4034).
/// Pipeline:
///
///   1. Patch the embedded uasset template — replace template SKU "12286"
///      with the caller's 5-digit SKU (same length, no offset shift) and
///      patch the FName number at 0x29D from `12287` to `sku + 1`.
///   2. Decode the embedded standee JPEG → re-encode as PNG (texconv only
///      reads bitmap/PNG/DDS).
///   3. Run texconv to produce a 512×512 DXT5 mip-0 .dds.
///   4. Strip the DDS header (128B, or 148B for DX10), pad/truncate the
///      pixel data to exactly `kThumbTexPixelSize` bytes (262144).
///   5. Assemble the new uexp = `thumbUexpHeader` + pixel data + `kThumbTexTrailing`.
///
/// The result is two byte buffers; PakBuilder writes them under
/// `RetroRewind/Content/VideoStore/asset/prop/Standees/Thumbnail/T_Standees_Collection_<sku>.uasset|.uexp`.

class StandeeThumbnailBuildResult {
  final Uint8List uassetBytes;
  final Uint8List uexpBytes;
  final String relativePath;

  const StandeeThumbnailBuildResult({
    required this.uassetBytes,
    required this.uexpBytes,
    required this.relativePath,
  });
}

class StandeeThumbnailBuildError implements Exception {
  final String code; // E004 / E007
  final String message;
  const StandeeThumbnailBuildError(this.code, this.message);
  @override
  String toString() => '[$code] standee thumbnail: $message';
}

class StandeeThumbnailBuilder {
  final StandeeTemplates templates;
  final AppConfig config;

  StandeeThumbnailBuilder(this.templates, this.config);

  /// Build the thumbnail asset pair for a New Release.
  ///
  /// [sku] must be exactly 5 digits — the same-length replacement Python
  /// does at Z. 3956-3958 only works when length matches.
  /// [shape] must be "A", "B", or "C".
  Future<StandeeThumbnailBuildResult> build({
    required int sku,
    required String shape,
  }) async {
    final skuStr = sku.toString();
    if (skuStr.length != 5) {
      throw StandeeThumbnailBuildError(
          'E004', 'SKU must be exactly 5 digits, got $sku');
    }

    // 1) Patch uasset — same-length SKU swap + FName-number patch.
    final ua = Uint8List.fromList(templates.thumbUasset);
    _replaceAllSameLength(
      ua,
      _ascii(kThumbTexTemplateSku.toString()),
      _ascii(skuStr),
    );

    final view = ByteData.sublistView(ua);
    final fnumOff = kThumbTexFnameNumOffset;
    if (fnumOff + 4 <= ua.length &&
        view.getUint32(fnumOff, Endian.little) == kThumbTexTemplateFnameNum) {
      view.setUint32(fnumOff, sku + 1, Endian.little);
    } else {
      // Fallback: scan the whole asset for the template's FName-number value.
      final oldF = ByteData(4)
        ..setUint32(0, kThumbTexTemplateFnameNum, Endian.little);
      final newF = ByteData(4)..setUint32(0, sku + 1, Endian.little);
      _replaceFirst(ua, oldF.buffer.asUint8List(), newF.buffer.asUint8List());
    }

    // 2) JPEG → PNG so texconv accepts the bitmap.
    final jpeg = templates.fullresFor(shape);
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) {
      throw StandeeThumbnailBuildError(
          'E004', 'failed to decode embedded standee JPEG for shape $shape');
    }
    final pngBytes = img.encodePng(decoded);

    // 3) Run texconv on a temp folder.
    final pixelData = await _runTexconv(pngBytes);

    // 4) Pad/truncate to the exact mip-0 pixel size the uasset expects.
    final padded = Uint8List(kThumbTexPixelSize);
    if (pixelData.length >= kThumbTexPixelSize) {
      padded.setRange(0, kThumbTexPixelSize, pixelData);
    } else {
      padded.setRange(0, pixelData.length, pixelData);
      // Remaining bytes are 0 by default.
    }

    // 5) Assemble uexp = header + pixel data + trailing.
    final uexp = Uint8List(
      templates.thumbUexpHeader.length +
          padded.length +
          kThumbTexTrailing.length,
    );
    var off = 0;
    uexp.setRange(off, off + templates.thumbUexpHeader.length,
        templates.thumbUexpHeader);
    off += templates.thumbUexpHeader.length;
    uexp.setRange(off, off + padded.length, padded);
    off += padded.length;
    uexp.setRange(off, off + kThumbTexTrailing.length, kThumbTexTrailing);

    final relativePath =
        'RetroRewind/Content/VideoStore/asset/prop/Standees/Thumbnail/'
        'T_Standees_Collection_$skuStr';

    return StandeeThumbnailBuildResult(
      uassetBytes: ua,
      uexpBytes: uexp,
      relativePath: relativePath,
    );
  }

  /// Run texconv on [pngBytes] and return the raw DXT5 pixel data with the
  /// DDS header stripped.  Mirrors Python Z. 3978-4017.
  Future<Uint8List> _runTexconv(Uint8List pngBytes) async {
    final tmp = await Directory.systemTemp.createTemp('rr_standee_');
    try {
      final pngPath = p.join(tmp.path, 'standee.png');
      await File(pngPath).writeAsBytes(pngBytes);

      final result = await Process.run(
        config.texconv,
        [
          '-f', 'DXT5',
          '-w', '512',
          '-h', '512',
          '-m', '1',
          '-srgb',
          '-o', tmp.path,
          '-y',
          pngPath,
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw StandeeThumbnailBuildError(
            'E007', 'texconv failed (${result.exitCode}): ${result.stderr}');
      }

      final ddsPath = p.join(tmp.path, 'standee.dds');
      final ddsFile = File(ddsPath);
      if (!await ddsFile.exists()) {
        throw const StandeeThumbnailBuildError(
            'E007', 'texconv produced no DDS');
      }
      final dds = await ddsFile.readAsBytes();

      // DDS header is 128 bytes, 148 if FourCC is "DX10" (Python Z. 4002-4007).
      var headerSize = 128;
      if (dds.length > 148) {
        if (dds[84] == 0x44 &&
            dds[85] == 0x58 &&
            dds[86] == 0x31 &&
            dds[87] == 0x30) {
          headerSize = 148;
        }
      }
      return Uint8List.sublistView(dds, headerSize);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // best effort
      }
    }
  }
}

// ── tiny byte-buffer helpers (kept local so the public surface stays slim) ──

List<int> _ascii(String s) => s.codeUnits;

void _replaceAllSameLength(Uint8List buf, List<int> needle, List<int> repl) {
  if (needle.length != repl.length) {
    throw ArgumentError('same-length only');
  }
  if (needle.isEmpty) return;
  final last = buf.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (buf[i + j] != needle[j]) continue outer;
    }
    for (var j = 0; j < repl.length; j++) {
      buf[i + j] = repl[j];
    }
    i += needle.length - 1;
  }
}

void _replaceFirst(Uint8List buf, List<int> needle, List<int> repl) {
  if (needle.isEmpty || needle.length != repl.length) return;
  final last = buf.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (buf[i + j] != needle[j]) continue outer;
    }
    for (var j = 0; j < repl.length; j++) {
      buf[i + j] = repl[j];
    }
    return;
  }
}
