import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/domain/entities/texture_replacement.dart';

void main() {
  group('TextureReplacement.fromJson', () {
    test('parses full Python-style entry', () {
      final r = TextureReplacement.fromJson({
        'path': 'C:/img.png',
        'offset_x': 17,
        'offset_y': -197,
        'zoom': 0.778,
      });
      expect(r.path, 'C:/img.png');
      expect(r.offsetX, 17);
      expect(r.offsetY, -197);
      expect(r.zoom, closeTo(0.778, 1e-9));
    });

    test('accepts bare-string entry like Python does', () {
      // RR_VHS_Tool.py:5584 — `entry["path"] if isinstance(entry, dict) else entry`.
      final r = TextureReplacement.fromJson('C:/img.png');
      expect(r.path, 'C:/img.png');
      expect(r.offsetX, 0);
      expect(r.offsetY, 0);
      expect(r.zoom, 1.0);
    });

    test('defaults are applied when keys are missing', () {
      final r = TextureReplacement.fromJson({'path': 'C:/img.png'});
      expect(r.offsetX, 0);
      expect(r.offsetY, 0);
      expect(r.zoom, 1.0);
    });

    test('rejects entries without a path', () {
      expect(() => TextureReplacement.fromJson({'offset_x': 0}),
          throwsFormatException);
      expect(() => TextureReplacement.fromJson({'path': ''}),
          throwsFormatException);
    });
  });

  group('TextureReplacement.mapFromJsonString', () {
    test('round-trips the production replacements.json shape', () {
      // Same shape as the user's actual file in
      // C:/Users/Sascha/Documents/MODDING/Tools/replacements.json.
      const src = '''
        {
          "T_Bkg_Wst_001": {
            "path": "C:/Users/Sascha/Downloads/Movies/Moonstruck (1987).jpg",
            "offset_x": 17,
            "offset_y": -197,
            "zoom": 0.778
          },
          "T_Bkg_Adu_001": {
            "path": "C:/img.jpg",
            "offset_x": 0,
            "offset_y": 0,
            "zoom": 1.0
          }
        }
      ''';
      final m = TextureReplacement.mapFromJsonString(src);
      expect(m.keys, ['T_Bkg_Wst_001', 'T_Bkg_Adu_001']);
      expect(m['T_Bkg_Wst_001']!.zoom, closeTo(0.778, 1e-9));
      expect(m['T_Bkg_Adu_001']!.zoom, 1.0);
    });

    test('rejects a non-object root', () {
      expect(() => TextureReplacement.mapFromJsonString('[]'),
          throwsFormatException);
    });
  });

  group('parseGenreFromTextureName', () {
    test('extracts a known genre code', () {
      expect(parseGenreFromTextureName('T_Bkg_Hor_001')?.code, 'Hor');
      expect(parseGenreFromTextureName('T_Bkg_Wst_001')?.name, 'Western');
    });

    test('returns null for unknown codes or malformed names', () {
      expect(parseGenreFromTextureName('T_Bkg_Zzz_001'), isNull);
      expect(parseGenreFromTextureName('not a texture'), isNull);
      expect(parseGenreFromTextureName('T_Bkg'), isNull);
    });
  });
}
