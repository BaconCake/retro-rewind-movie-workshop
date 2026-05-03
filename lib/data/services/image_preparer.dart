import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/constants/genres.dart';

/// Mode controlling how the user image is fitted onto the 1024×2048 canvas.
enum CanvasFit {
  /// Cover the full canvas, crop overflow.  Used by both `prepare_image` and
  /// `prepare_image_fullcanvas` in the Python tool — the only practical
  /// difference is which of those two helpers got called for which texture
  /// type, and that distinction is preserved by `T_New` callers passing
  /// [fullCanvas].  RR_VHS_Tool.py:5542-5573.
  bkg,

  /// Same cover-fit logic, kept as a separate enum value so future divergence
  /// (e.g. if T_New ever needs different scaling) doesn't ripple through
  /// callers.
  fullCanvas,
}

/// Resize and pad a user image onto the standard 1024×2048 RGB canvas used
/// by all RR Movie Workshop textures, then write the result as PNG.
///
/// Ports `prepare_image` / `prepare_image_fullcanvas` from RR_VHS_Tool.py
/// (lines 5542-5573) — both helpers in Python share identical logic; the
/// distinction is preserved here only as a hook for future divergence.
///
/// The output PNG is what `texconv -f DXT1` reads in the next step of the
/// injection pipeline.
class ImagePreparer {
  const ImagePreparer();

  /// Read [inputPath], cover-fit it to 1024×2048, apply [offsetX]/[offsetY]/
  /// [zoom], and write a PNG to [outputPath].  Throws [FileSystemException]
  /// if the input file can't be read or decoded.
  Future<void> prepare({
    required String inputPath,
    required String outputPath,
    int offsetX = 0,
    int offsetY = 0,
    double zoom = 1.0,
    CanvasFit fit = CanvasFit.bkg,
  }) async {
    final bytes = await File(inputPath).readAsBytes();
    final pngBytes = encode(
      sourceBytes: bytes,
      offsetX: offsetX,
      offsetY: offsetY,
      zoom: zoom,
      fit: fit,
    );
    await File(outputPath).writeAsBytes(pngBytes);
  }

  /// Pure in-memory variant: decode [sourceBytes], cover-fit, return PNG bytes.
  /// Exposed separately so unit tests can run without touching disk.
  Uint8List encode({
    required Uint8List sourceBytes,
    int offsetX = 0,
    int offsetY = 0,
    double zoom = 1.0,
    CanvasFit fit = CanvasFit.bkg,
  }) {
    final source = img.decodeImage(sourceBytes);
    if (source == null) {
      throw const FileSystemException(
          'Could not decode source image (unsupported format?)');
    }
    // Convert to RGB-equivalent (3 channels).  package:image stores 4 channels
    // by default; the canvas paste below ignores alpha when both surfaces are
    // RGB.  Python's `.convert('RGB')` is the same intent.
    final rgb = source.numChannels == 3
        ? source
        : source.convert(numChannels: 3);

    // Cover-fit: scale so the larger of the two ratios wins.  Identical to
    // Python lines 5547 and 5564 (max of W/imgW and H/imgH).
    final coverScale = (kTextureBkgWidth / rgb.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final coverScale2 = (kTextureBkgHeight / rgb.height)
        .clamp(0.0, double.infinity)
        .toDouble();
    final baseScale = coverScale > coverScale2 ? coverScale : coverScale2;
    final scale = baseScale * zoom;
    final nw = (rgb.width * scale).toInt();
    final nh = (rgb.height * scale).toInt();

    // package:image's `cubic` is the closest equivalent we have to PIL's
    // LANCZOS.  Output goes through DXT1 + mip generation in texconv, which
    // dwarfs any small difference between cubic and lanczos at this stage.
    final resized = img.copyResize(
      rgb,
      width: nw,
      height: nh,
      interpolation: img.Interpolation.cubic,
    );

    // Black 1024×2048 RGB canvas.
    final canvas = img.Image(
      width: kTextureBkgWidth,
      height: kTextureBkgHeight,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));

    // Center, then apply user offset (Python lines 5552-5553, 5570-5571).
    var dstX = (kTextureBkgWidth - nw) ~/ 2 + offsetX;
    var dstY = (kTextureBkgHeight - nh) ~/ 2 + offsetY;

    // package:image's compositeImage does not auto-clip negative dst
    // coordinates the way PIL.Image.paste does, so we have to translate
    // negative dst into a srcX/srcY/srcW/srcH crop ourselves. Without this
    // a 50×50 source with cover-fit (which becomes 2048×2048) gets pasted
    // at dstX=-512 and the canvas stays black.
    var srcX = 0;
    var srcY = 0;
    var srcW = resized.width;
    var srcH = resized.height;
    if (dstX < 0) {
      srcX = -dstX;
      srcW -= srcX;
      dstX = 0;
    }
    if (dstY < 0) {
      srcY = -dstY;
      srcH -= srcY;
      dstY = 0;
    }
    if (srcW > 0 && srcH > 0) {
      img.compositeImage(
        canvas,
        resized,
        dstX: dstX,
        dstY: dstY,
        srcX: srcX,
        srcY: srcY,
        srcW: srcW,
        srcH: srcH,
      );
    }

    // The fit enum is currently a no-op — Python's two helpers do the same
    // thing.  Kept as a parameter so a future divergence stays caller-safe.
    assert(fit == CanvasFit.bkg || fit == CanvasFit.fullCanvas);

    return Uint8List.fromList(img.encodePng(canvas));
  }
}
