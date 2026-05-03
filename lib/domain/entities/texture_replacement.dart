import 'dart:convert';

/// One entry in `replacements.json`.  Schema mirrors the Python tool exactly
/// so users can switch between Python and Flutter without losing data
/// (RR_VHS_Tool.py:5613-5615 reads the same fields).
///
/// Keyed by texture name (e.g. `T_Bkg_Hor_001`) at the JSON map level — the
/// key is not stored on this object.
class TextureReplacement {
  /// Absolute path to the user-supplied source image (PNG/JPG).
  final String path;

  /// Horizontal pixel offset applied after centering the image on the
  /// 1024×2048 canvas. Defaults to 0.
  final int offsetX;

  /// Vertical pixel offset applied after centering. Defaults to 0.
  final int offsetY;

  /// Multiplier on the cover-fit scale.  1.0 = exactly cover the canvas,
  /// > 1.0 = zoom in (overflow cropped), < 1.0 = zoom out (black bars).
  final double zoom;

  const TextureReplacement({
    required this.path,
    this.offsetX = 0,
    this.offsetY = 0,
    this.zoom = 1.0,
  });

  factory TextureReplacement.fromJson(Object json) {
    // Python supports two shapes: a bare string (path only) or a full dict.
    // RR_VHS_Tool.py:5584 — `entry["path"] if isinstance(entry, dict) else entry`.
    if (json is String) {
      return TextureReplacement(path: json);
    }
    if (json is! Map) {
      throw FormatException(
          'TextureReplacement entry must be a string or object, got '
          '${json.runtimeType}');
    }
    final m = json;
    final path = m['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException(
          'TextureReplacement.path must be a non-empty string');
    }
    return TextureReplacement(
      path: path,
      offsetX: (m['offset_x'] as num?)?.toInt() ?? 0,
      offsetY: (m['offset_y'] as num?)?.toInt() ?? 0,
      zoom: (m['zoom'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, Object> toJson() => {
        'path': path,
        'offset_x': offsetX,
        'offset_y': offsetY,
        'zoom': zoom,
      };

  static Map<String, TextureReplacement> mapFromJsonString(String src) {
    final decoded = jsonDecode(src);
    if (decoded is! Map) {
      throw const FormatException(
          'replacements.json root must be a JSON object');
    }
    return {
      for (final e in decoded.entries)
        e.key as String: TextureReplacement.fromJson(e.value as Object),
    };
  }

  static String mapToJsonString(Map<String, TextureReplacement> map) =>
      const JsonEncoder.withIndent('  ').convert(
        {for (final e in map.entries) e.key: e.value.toJson()},
      );
}
