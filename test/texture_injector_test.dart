import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/uexp_template.dart';
import 'package:rr_movie_workshop/data/repositories/texture_injector_impl.dart';

/// Build a synthetic DDS file with [headerSize] header bytes followed by
/// [pixelBytes].  When [dx10] is true the FourCC at offset 84 is set to
/// 'DX10' so the injector treats it as an extended-header DDS (148 bytes).
Uint8List _fakeDds({
  required int headerSize,
  required Uint8List pixelBytes,
  bool dx10 = false,
}) {
  final out = Uint8List(headerSize + pixelBytes.length);
  if (dx10) {
    out[84] = 0x44; // 'D'
    out[85] = 0x58; // 'X'
    out[86] = 0x31; // '1'
    out[87] = 0x30; // '0'
  }
  out.setRange(headerSize, out.length, pixelBytes);
  return out;
}

/// Pseudo-random pixel pattern that's deterministic and big enough to cover
/// the canonical TNEW_UBULK_SIZE plus all 7 inline-mip slices.
Uint8List _patternPixels(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + 7) & 0xFF;
  }
  return out;
}

void main() {
  group('texconvArgs', () {
    test('argv is locked to the exact Python flag list', () {
      // RR_VHS_Tool.py:5621-5622 — any change here would shift the output
      // bytes (DDS header content is filter-dependent).
      final args = TextureInjectorImpl.texconvArgs(
        texconv: 'C:/tools/texconv.exe',
        tmpDir: 'C:/tmp/abc',
        inputPng: 'C:/tmp/abc/T_Bkg_Hor_001.png',
      );
      expect(args, [
        'C:/tools/texconv.exe',
        '-f', 'DXT1',
        '-w', '1024',
        '-h', '2048',
        '-if', 'LINEAR',
        '-srgb',
        '-o', 'C:/tmp/abc',
        '-y', 'C:/tmp/abc/T_Bkg_Hor_001.png',
      ]);
    });
  });

  group('composeArtifacts — DDS header stripping', () {
    test('standard 128-byte header is stripped', () {
      final raw = _patternPixels(kTNewUbulkSize);
      final dds = _fakeDds(headerSize: 128, pixelBytes: raw);

      final artifacts = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: Uint8List(2000), // not template-sized → kept verbatim
        baseUasset: Uint8List.fromList([1, 2, 3]),
      );

      expect(artifacts.ubulk.length, kTNewUbulkSize);
      expect(artifacts.ubulk[0], raw[0]);
      expect(artifacts.ubulk[kTNewUbulkSize - 1], raw[kTNewUbulkSize - 1]);
    });

    test('DX10 extended header (148 bytes) is detected and stripped', () {
      final raw = _patternPixels(kTNewUbulkSize);
      final dds = _fakeDds(headerSize: 148, pixelBytes: raw, dx10: true);

      final artifacts = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: Uint8List(2000),
        baseUasset: Uint8List(0),
      );

      expect(artifacts.ubulk[0], raw[0],
          reason: 'first ubulk byte must be the first pixel byte after the '
              '148-byte DX10 header');
    });
  });

  group('composeArtifacts — ubulk size normalisation', () {
    test('truncates raw pixels longer than TNEW_UBULK_SIZE', () {
      final tooBig = _patternPixels(kTNewUbulkSize + 12345);
      final dds = _fakeDds(headerSize: 128, pixelBytes: tooBig);

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: Uint8List(2000),
        baseUasset: Uint8List(0),
      );
      expect(a.ubulk.length, kTNewUbulkSize);
      // Last byte should be from raw[TNEW_UBULK_SIZE - 1], not from the tail.
      expect(a.ubulk[kTNewUbulkSize - 1], tooBig[kTNewUbulkSize - 1]);
    });

    test('zero-pads raw pixels shorter than TNEW_UBULK_SIZE', () {
      final tooSmall = _patternPixels(1000);
      final dds = _fakeDds(headerSize: 128, pixelBytes: tooSmall);

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: Uint8List(2000),
        baseUasset: Uint8List(0),
      );
      expect(a.ubulk.length, kTNewUbulkSize);
      expect(a.ubulk[999], tooSmall[999]);
      expect(a.ubulk[1000], 0, reason: 'tail must be zero-padded');
      expect(a.ubulk[kTNewUbulkSize - 1], 0);
    });
  });

  group('composeArtifacts — uexp inline mip patching', () {
    test('template-sized base uexp gets mips 5-11 patched from DDS', () {
      // Total raw needs to cover TNEW_UBULK_SIZE + all inline mip slices.
      final mipBytesTotal =
          kUexpInlineMipMap.fold<int>(0, (a, e) => a + e.$3);
      final raw = _patternPixels(kTNewUbulkSize + mipBytesTotal + 100);
      final dds = _fakeDds(headerSize: 128, pixelBytes: raw);

      // Base uexp = the canonical template, all-zero overlay so we can
      // detect any byte we wrote.
      final baseUexp = Uint8List.fromList(kTBkgUexpTemplate);

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: baseUexp,
        baseUasset: Uint8List(0),
      );

      var ddsCursor = kTNewUbulkSize;
      for (final (level, off, size) in kUexpInlineMipMap) {
        final patched = a.uexp.sublist(off, off + size);
        final expected = raw.sublist(ddsCursor, ddsCursor + size);
        expect(patched, expected,
            reason: 'mip $level at uexp offset 0x${off.toRadixString(16)} '
                'should mirror raw[$ddsCursor..${ddsCursor + size}]');
        ddsCursor += size;
      }
    });

    test('non-template uexp is preserved verbatim (existing base-game slot)',
        () {
      final raw = _patternPixels(kTNewUbulkSize + 5000);
      final dds = _fakeDds(headerSize: 128, pixelBytes: raw);

      // Pretend this is an existing base-game uexp — much bigger than 1702.
      final baseUexp = Uint8List(8888);
      for (var i = 0; i < baseUexp.length; i++) {
        baseUexp[i] = (i * 13) & 0xFF;
      }

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: dds,
        baseUexp: baseUexp,
        baseUasset: Uint8List(0),
      );

      expect(a.uexp, baseUexp,
          reason: 'Python only patches inline mips when len == 1702 '
              '(RR_VHS_Tool.py:5680); other base uexps must be untouched.');
    });
  });

  test('uasset is copied byte-for-byte when input has no valid structure', () {
    // Random bytes don't parse as a uasset (pkgLen at 0x20 reads as garbage,
    // bounds check trips and the SerialSize patch is a no-op).
    final base = Uint8List.fromList(List.generate(500, (i) => i & 0xFF));
    final a = TextureInjectorImpl.composeArtifacts(
      ddsBytes: _fakeDds(
          headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
      baseUexp: Uint8List(2000),
      baseUasset: base,
    );
    expect(a.uasset, base);
  });

  group('composeArtifacts — SerialSize patch (fat-donor bug fix)', () {
    /// Build a minimal synthetic uasset with the export-entry layout the
    /// patch reads:
    ///   0x00..0x1F : 32 bytes header (zeros)
    ///   0x20       : i32 pkgLen
    ///   0x24..     : PackageName bytes (length pkgLen)
    ///   fse        : 0x24 + pkgLen
    ///   fse+32     : i32 exportOff
    ///   exportOff+28 : i64 SerialSize  ← patched to uexp.length - 4
    Uint8List _syntheticUasset({
      required int initialSerialSize,
      int pkgLen = 10,
      int totalLen = 260,
    }) {
      final out = Uint8List(totalLen);
      final bd = ByteData.sublistView(out);
      bd.setInt32(0x20, pkgLen, Endian.little);
      final fse = 0x24 + pkgLen;
      const exportOff = 200;
      bd.setInt32(fse + 32, exportOff, Endian.little);
      bd.setInt64(exportOff + 28, initialSerialSize, Endian.little);
      return out;
    }

    int _serialSizeOf(Uint8List uasset, {int pkgLen = 10}) {
      final bd = ByteData.sublistView(uasset);
      final fse = 0x24 + pkgLen;
      final exportOff = bd.getInt32(fse + 32, Endian.little);
      return bd.getInt64(exportOff + 28, Endian.little);
    }

    test('fat-donor SerialSize (3082) is overwritten with uexp.length - 4',
        () {
      // Reproduces the Act_08 / Act_10 crash: donor uasset claims a 3082-B
      // export, but composeArtifacts ships the 1702-B template uexp.
      // Without the patch, UE5 over-reads → ACCESS_VIOLATION.
      final base = _syntheticUasset(initialSerialSize: 3082);
      final templateUexp = Uint8List.fromList(kTBkgUexpTemplate);
      expect(templateUexp.length, 1702,
          reason: 'sanity: template is the canonical 1702-byte size');

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: _fakeDds(
            headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
        baseUexp: templateUexp,
        baseUasset: base,
      );

      expect(_serialSizeOf(a.uasset), 1698,
          reason: 'SerialSize must equal uexp.length - 4 (template = 1702)');
    });

    test('normal SerialSize (1698) survives patch unchanged (idempotent)', () {
      final base = _syntheticUasset(initialSerialSize: 1698);
      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: _fakeDds(
            headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
        baseUexp: Uint8List.fromList(kTBkgUexpTemplate),
        baseUasset: base,
      );
      expect(_serialSizeOf(a.uasset), 1698);
    });

    test('SerialSize is recomputed from shipped uexp size, not the template',
        () {
      // When the uexp is NOT the 1702 template (existing base-game slot),
      // the patch should reflect that file's actual size — not silently
      // assume 1698.
      final base = _syntheticUasset(initialSerialSize: 3082);
      final largeUexp = Uint8List(8888);

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: _fakeDds(
            headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
        baseUexp: largeUexp,
        baseUasset: base,
      );

      expect(_serialSizeOf(a.uasset), 8888 - 4,
          reason: 'patch must always equal uexp.length - 4, regardless of '
              'donor SerialSize or uexp shape — this is what makes the fix '
              'future-proof against unknown fat donors.');
    });

    test('invariant: SerialSize always equals uexp.length - 4 post-compose',
        () {
      // Sweep a few representative SerialSize / uexp-length combinations.
      const cases = <(int, int)>[
        (1698, 1702),   // canonical template
        (3082, 1702),   // Act fat-donor bug case
        (1698, 8888),   // existing base-game uexp
        (3082, 3086),   // ship the matching fat uexp (theoretical)
      ];
      for (final (donorSerial, uexpLen) in cases) {
        final base = _syntheticUasset(initialSerialSize: donorSerial);
        final a = TextureInjectorImpl.composeArtifacts(
          ddsBytes: _fakeDds(
              headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
          baseUexp: Uint8List(uexpLen),
          baseUasset: base,
        );
        expect(_serialSizeOf(a.uasset), uexpLen - 4,
            reason: 'donor=$donorSerial, uexp=$uexpLen — '
                'invariant SerialSize == uexp.length - 4 must hold');
      }
    });

    test('garbage uasset that does not parse is passed through unchanged', () {
      // pkgLen at 0x20 is a huge int that puts fse out of bounds — the
      // patch's bounds checks should make this a safe no-op.
      final base = Uint8List(64);
      ByteData.sublistView(base).setInt32(0x20, 0x7FFFFFFF, Endian.little);
      final originalCopy = Uint8List.fromList(base);

      final a = TextureInjectorImpl.composeArtifacts(
        ddsBytes: _fakeDds(
            headerSize: 128, pixelBytes: _patternPixels(kTNewUbulkSize)),
        baseUexp: Uint8List(2000),
        baseUasset: base,
      );

      expect(a.uasset, originalCopy);
    });
  });
}
