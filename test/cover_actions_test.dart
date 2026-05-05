import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rr_movie_workshop/data/services/cover_actions.dart';

/// Tests for the slice 4c image-action helpers.  The Python tool has no
/// equivalent test coverage, so these lock in the parity numbers for a
/// representative cover image dimension (800×1200, the typical 2:3 movie
/// poster aspect) plus the rotate round-trip.
void main() {
  group('computeFitVisibleTransform — layout 1 (800×1200 poster)', () {
    test('cover-fits the cyan visible rect (no padding inside)', () {
      // Visible rect from layoutVisibleRect(1) rounded to int: top=30,
      // bot=1622, left=31, right=1024.
      //   safe_w   = 993, safe_h = 1592, safe_cx = 31 + 993//2 = 527.
      //   base     = max(1024/800, 2048/1200) = 1.7066…
      //   fit      = max(993/800, 1592/1200)  = 1.32666…
      //   zoom     = ceil(0.77734375 * 1000)/1000 = 0.778
      //   actual   = 1.7066… * 0.778 = 1.32785…
      //   img_w    = int(800  * 1.32785…) = 1062
      //   img_h    = int(1200 * 1.32785…) = 1593
      //   default_x= (1024 - 1062)//2 = -19
      //   default_y= (2048 - 1593)//2 = 227
      //   offset_x = 527 - 1062//2 - (-19) = 15
      //   offset_y = 30 - 227              = -197
      final t = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 1,
      );
      expect(t, isNotNull);
      expect(t!.zoom, closeTo(0.778, 1e-9));
      expect(t.offsetX, 15);
      expect(t.offsetY, -197);
    });
  });

  group('computeFitVisibleTransform — layout 4 (left-aligned visible rect)', () {
    test('uses layout-specific visLeft (4) and visTop (0)', () {
      // Layout 4 visible rect (rounded): top=0, bot=1623, left=4, right=1024.
      //   safe_w  = 1020, safe_h = 1623, safe_cx = 4 + 510 = 514.
      //   fit     = max(1020/800, 1623/1200) = 1.3525
      //   base    = 1.7066…
      //   zoom    = ceil(0.79248 * 1000)/1000 = 0.793
      //   actual  = 1.7066… * 0.793 = 1.35338…
      //   img_w   = int(800  * 1.35338…) = 1082
      //   img_h   = int(1200 * 1.35338…) = 1624
      //   default_x = (1024-1082)//2 = -29
      //   default_y = (2048-1624)//2 =  212
      //   offset_x  = 514 - 541 - (-29) =   2
      //   offset_y  =   0 - 212         = -212
      final t = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 4,
      );
      expect(t, isNotNull);
      expect(t!.zoom, closeTo(0.793, 1e-9));
      expect(t.offsetX, 2);
      expect(t.offsetY, -212);
    });
  });

  group('computeFitVisibleTransform — narrow image (cover-fit picks width)', () {
    test('uses width-fit when the image is narrower than the visible aspect',
        () {
      // 600×1200 image (aspect 0.5) vs. layout 1 visible 993×1592.
      //   base   = max(1024/600, 2048/1200) = 1.7066… (both tied)
      //   fit    = max(993/600, 1592/1200)  = 1.655 (width-driven)
      //   zoom   = ceil(0.96972 * 1000)/1000 = 0.97
      //   actual = 1.7066… * 0.97 = 1.65547…
      //   img_w  = int(600  * 1.65547…) = 993
      //   img_h  = int(1200 * 1.65547…) = 1986
      //   default_x = (1024-993)//2 = 15
      //   default_y = (2048-1986)//2 = 31
      //   offset_x  = 527 - 993//2 - 15 = 16
      //   offset_y  =  30 - 31          = -1
      final t = computeFitVisibleTransform(
        imageWidth: 600,
        imageHeight: 1200,
        layout: 1,
      );
      expect(t, isNotNull);
      expect(t!.zoom, closeTo(0.97, 1e-9));
      expect(t.offsetX, 16);
      expect(t.offsetY, -1);
    });
  });

  group('computeFitVisibleTransform — out-of-range layout', () {
    test('layout 0 falls back to layout 1', () {
      final t0 = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 0,
      );
      final t1 = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 1,
      );
      expect(t0!.zoom, t1!.zoom);
      expect(t0.offsetX, t1.offsetX);
      expect(t0.offsetY, t1.offsetY);
    });

    test('layout 9 falls back to layout 1', () {
      final t9 = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 9,
      );
      final t1 = computeFitVisibleTransform(
        imageWidth: 800,
        imageHeight: 1200,
        layout: 1,
      );
      expect(t9!.zoom, t1!.zoom);
      expect(t9.offsetX, t1.offsetX);
      expect(t9.offsetY, t1.offsetY);
    });
  });

  group('computeFitVisibleTransform — invalid input', () {
    test('zero width returns null', () {
      expect(
        computeFitVisibleTransform(
          imageWidth: 0,
          imageHeight: 1200,
          layout: 1,
        ),
        isNull,
      );
    });

    test('zero height returns null', () {
      expect(
        computeFitVisibleTransform(
          imageWidth: 800,
          imageHeight: 0,
          layout: 1,
        ),
        isNull,
      );
    });
  });

  group('kFillCanvasTransform', () {
    test('is the identity transform — full canvas, zoom 1', () {
      expect(kFillCanvasTransform.offsetX, 0);
      expect(kFillCanvasTransform.offsetY, 0);
      expect(kFillCanvasTransform.zoom, 1.0);
    });
  });

  group('applyDragSnap — drag-time snapping (slice 4d)', () {
    // Setup: 800×1200 image, layout 1, zoom = 0.778 (Fit Visible result).
    //   baseScale*zoom = 1.7066… * 0.778 = 1.32785…
    //   img_w_tex      = 1062
    //   img_h_tex      = 1593
    //   img_default_x  = floor((1024 - 1062) / 2) = -19
    //   img_default_y  = floor((2048 - 1593) / 2) = 227
    //   safeCx (from layoutVisibleRect rounded) = floor((31 + 1024)/2) = 527
    //   safeCy = floor((30 + 1622)/2) = 826
    //
    //   X targets:
    //     cyan_center_x = 527 - 531 - (-19) =  15  (centre — draws guide)
    //     cyan_left     =  31 - (-19)        =  50
    //     cyan_right    = 1024 - 1062 - (-19) = -19
    //     canvas_left   = -(-19)              =  19
    //     canvas_right  = (1024-1062) - (-19) = -19
    //
    //   Y targets:
    //     cyan_center_y = 826 - 796 - 227 = -197  (centre — draws guide)
    //     cyan_top      =  30 - 227        = -197
    //     cyan_bottom   = 1622 - 1593 - 227 = -198
    //     canvas_top    = -227
    //     canvas_bottom = (2048 - 1593) - 227 = 228

    SnappedOffset run(int x, int y) => applyDragSnap(
          rawOffsetX: x,
          rawOffsetY: y,
          imageWidth: 800,
          imageHeight: 1200,
          zoom: 0.778,
          layout: 1,
        );

    test('passes raw offset through when no target is in range', () {
      final s = run(200, 500);
      expect(s.offsetX, 200);
      expect(s.offsetY, 500);
      expect(s.centerSnapX, isFalse);
      expect(s.centerSnapY, isFalse);
    });

    test('snaps to centre on both axes when at centre values', () {
      final s = run(15, -197);
      expect(s.offsetX, 15);
      expect(s.offsetY, -197);
      expect(s.centerSnapX, isTrue);
      expect(s.centerSnapY, isTrue);
    });

    test('pulls in from within 40-px range to centre target', () {
      // 50 is 35 px from centre (15) and 0 px from cyan_left (50) —
      // cyan_left wins because it's closer.
      final s = run(50, -197);
      expect(s.offsetX, 50);
      expect(s.centerSnapX, isFalse, reason: 'cyan_left isn\'t a centre');
      expect(s.offsetY, -197);
      expect(s.centerSnapY, isTrue);
    });

    test('within 40 of centre but no closer target snaps to centre', () {
      // 30 is 15 px from centre (15), 20 px from cyan_left (50), 11 from
      // canvas_left (19), 49 from cyan_right/canvas_right (-19).  Nearest
      // is canvas_left (11 px away).
      final s = run(30, 100);
      expect(s.offsetX, 19); // canvas_left
      expect(s.centerSnapX, isFalse);
    });

    test('chooses nearest among multiple in-range targets', () {
      // Y = -210 is 13 px from centre (-197), 12 px from cyan_bottom
      // (-198), 17 px from canvas_top? 17 from -227 actually.  Closest is
      // cyan_bottom at -198.
      final s = run(15, -210);
      expect(s.offsetY, -198);
      expect(s.centerSnapY, isFalse, reason: 'cyan_bottom isn\'t a centre');
    });

    test('disabled (snapRadius = 0) leaves the offset untouched', () {
      final s = applyDragSnap(
        rawOffsetX: 20,
        rawOffsetY: -190,
        imageWidth: 800,
        imageHeight: 1200,
        zoom: 0.778,
        layout: 1,
        snapRadius: 0,
      );
      expect(s.offsetX, 20);
      expect(s.offsetY, -190);
      expect(s.centerSnapX, isFalse);
      expect(s.centerSnapY, isFalse);
    });

    test('zero-dimension image returns raw offset (defensive)', () {
      final s = applyDragSnap(
        rawOffsetX: 100,
        rawOffsetY: -150,
        imageWidth: 0,
        imageHeight: 0,
        zoom: 1.0,
        layout: 1,
      );
      expect(s.offsetX, 100);
      expect(s.offsetY, -150);
    });
  });

  group('rotateCoverImageCw', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('rr_rotate_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('swaps width and height after a single rotation', () async {
      // 4×2 image, red pixel at (0, 0) → after 90° CW it should be 2×4
      // with the red pixel at (1, 0) (top-right of the rotated image).
      final src = img.Image(width: 4, height: 2);
      img.fill(src, color: img.ColorRgb8(0, 0, 0));
      src.setPixelRgb(0, 0, 255, 0, 0);

      final path = '${tmp.path}/test.png';
      File(path).writeAsBytesSync(img.encodePng(src));

      await rotateCoverImageCw(path);

      final rotated = img.decodePng(File(path).readAsBytesSync())!;
      expect(rotated.width, 2);
      expect(rotated.height, 4);

      final p = rotated.getPixel(1, 0);
      expect(p.r, 255);
      expect(p.g, 0);
      expect(p.b, 0);
    });

    test('four rotations restore the original dimensions', () async {
      final src = img.Image(width: 4, height: 2);
      img.fill(src, color: img.ColorRgb8(50, 100, 150));
      final path = '${tmp.path}/quad.png';
      File(path).writeAsBytesSync(img.encodePng(src));

      for (var i = 0; i < 4; i++) {
        await rotateCoverImageCw(path);
      }

      final back = img.decodePng(File(path).readAsBytesSync())!;
      expect(back.width, 4);
      expect(back.height, 2);
    });

    test('throws on a missing / undecodable file', () async {
      // Either FileSystemException (path not found) or FormatException
      // (bytes couldn't be decoded) — both are acceptable surface errors
      // for the caller's try/catch in slot_preview.dart.
      final path = '${tmp.path}/missing.png';
      expect(rotateCoverImageCw(path), throwsA(isA<Exception>()));
    });
  });
}
