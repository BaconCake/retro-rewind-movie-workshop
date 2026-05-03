import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/services/image_preparer.dart';

/// Build a solid-colour PNG in memory for use as a test source.
Uint8List _solidPng(int width, int height, int r, int g, int b) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  const preparer = ImagePreparer();

  test('output canvas is always 1024×2048 RGB', () {
    final src = _solidPng(50, 50, 255, 0, 0);
    final out = img.decodePng(preparer.encode(sourceBytes: src))!;
    expect(out.width, kTextureBkgWidth);
    expect(out.height, kTextureBkgHeight);
  });

  test('cover-fit fills the canvas with the source colour', () {
    // A square red source covering a 1024×2048 canvas with cover-fit will
    // overflow vertically.  Every pixel of the canvas should still be red
    // (not the black background) because the resized image covers the whole
    // canvas at zoom=1.0.
    final src = _solidPng(50, 50, 255, 0, 0);
    final out = img.decodePng(preparer.encode(sourceBytes: src))!;

    final centre = out.getPixel(out.width ~/ 2, out.height ~/ 2);
    expect(centre.r, 255);
    expect(centre.g, 0);
    expect(centre.b, 0);

    final edge = out.getPixel(0, 0);
    expect(edge.r, 255,
        reason: 'cover-fit must overflow horizontally, leaving no black bars');
  });

  test('zoom < 1.0 leaves a black border (no cover)', () {
    // With zoom 0.5 the image is half its cover-fit size, so the corners
    // of the canvas become black.
    final src = _solidPng(50, 50, 255, 0, 0);
    final out = img.decodePng(
        preparer.encode(sourceBytes: src, zoom: 0.5))!;

    final corner = out.getPixel(0, 0);
    expect(corner.r, 0);
    expect(corner.g, 0);
    expect(corner.b, 0);
  });

  test('offsetX produces a different canvas than no offset', () {
    // A precise pixel-level assertion would be brittle against cubic-vs-
    // Lanczos differences.  All we want to verify here is that offsetX
    // actually wires through to compositeImage — i.e. that the two outputs
    // are not byte-identical.
    final im = img.Image(width: 100, height: 100, numChannels: 3);
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 100; x++) {
        im.setPixel(
            x, y, x < 50 ? img.ColorRgb8(255, 0, 0) : img.ColorRgb8(0, 0, 255));
      }
    }
    final src = Uint8List.fromList(img.encodePng(im));

    final neutral = preparer.encode(sourceBytes: src);
    final shifted = preparer.encode(sourceBytes: src, offsetX: 200);

    expect(neutral.length, isNot(0));
    expect(shifted, isNot(equals(neutral)),
        reason: 'offsetX should change the encoded output');
  });
}
