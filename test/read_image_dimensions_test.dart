import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/services/cover_actions.dart';

/// Locks in the post-2026-05-12 behaviour: header-only dim read.  Used
/// by the shelf thumbnails on every tab switch — a regression that
/// reverts back to full-pixel decode would re-introduce the 1 s freeze
/// when opening a tab with many covers.
void main() {
  group('readImageDimensions', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_dims_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best-effort */}
    });

    Future<File> writePng(int width, int height) async {
      final img0 = img.Image(width: width, height: height, numChannels: 3);
      img.fill(img0, color: img.ColorRgb8(64, 96, 128));
      final bytes = img.encodePng(img0);
      final file = File(p.join(tmp.path, 'cover_${width}x$height.png'));
      await file.writeAsBytes(bytes);
      return file;
    }

    Future<File> writeJpg(int width, int height) async {
      final img0 = img.Image(width: width, height: height, numChannels: 3);
      img.fill(img0, color: img.ColorRgb8(200, 100, 50));
      final bytes = img.encodeJpg(img0);
      final file = File(p.join(tmp.path, 'cover_${width}x$height.jpg'));
      await file.writeAsBytes(bytes);
      return file;
    }

    test('returns correct dims for a small PNG', () async {
      final file = await writePng(640, 1280);
      final dims = await readImageDimensions(file.path);
      expect(dims, isNotNull);
      expect(dims!.width, 640);
      expect(dims.height, 1280);
    });

    test('returns correct dims for a small JPG', () async {
      final file = await writeJpg(800, 1200);
      final dims = await readImageDimensions(file.path);
      expect(dims, isNotNull);
      expect(dims!.width, 800);
      expect(dims.height, 1200);
    });

    test('returns null for a missing file', () async {
      final dims =
          await readImageDimensions(p.join(tmp.path, 'does_not_exist.png'));
      expect(dims, isNull);
    });

    test('returns null for a malformed file (random bytes)', () async {
      final f = File(p.join(tmp.path, 'garbage.png'));
      await f.writeAsBytes(List<int>.generate(2048, (i) => (i * 37) & 0xFF));
      final dims = await readImageDimensions(f.path);
      expect(dims, isNull);
    });

    test('handles a larger image (> 64 KB header probe limit)', () async {
      // Pixel-rich image whose encoded PNG exceeds 64 KB; verifies the
      // first-chunk path picks up the header from byte 0 of the file
      // regardless of total file size.  Use deterministic pseudo-random
      // pixel data so the PNG can't compress small.
      final img0 = img.Image(width: 1200, height: 1800, numChannels: 3);
      for (var y = 0; y < img0.height; y++) {
        for (var x = 0; x < img0.width; x++) {
          final r = (x * 31 + y * 17) & 0xFF;
          final g = (x * 19 + y * 23) & 0xFF;
          final b = (x * 13 + y * 29) & 0xFF;
          img0.setPixelRgb(x, y, r, g, b);
        }
      }
      final file = File(p.join(tmp.path, 'noisy_1200x1800.png'));
      await file.writeAsBytes(img.encodePng(img0));
      expect(file.lengthSync(), greaterThan(64 * 1024));

      final dims = await readImageDimensions(file.path);
      expect(dims, isNotNull);
      expect(dims!.width, 1200);
      expect(dims.height, 1800);
    });
  });
}
