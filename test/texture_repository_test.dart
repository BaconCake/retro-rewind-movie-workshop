import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/repositories/texture_repository_impl.dart';

void main() {
  group('TextureRepositoryImpl (slice 1 fallback path)', () {
    final repo = TextureRepositoryImpl();
    final all = repo.buildTextureList();

    test('produces the expected total slot count', () {
      // Sum of bkgCount across all 13 genres in the Python GENRES dict.
      final expected = kGenres.fold<int>(0, (s, g) => s + g.bkgCount);
      expect(all.length, expected);
    });

    test('slot count per genre matches Python GENRES["bkg"]', () {
      for (final g in kGenres) {
        final n = all.where((t) => t.genre == g.name).length;
        expect(n, g.bkgCount, reason: 'genre ${g.name}');
      }
    });

    test('uses 3-digit zero-padded index for slots < 100', () {
      // Action has 15 slots — every name should be T_Bkg_Act_001..T_Bkg_Act_015.
      final action = all.where((t) => t.genre == 'Action').toList();
      expect(action.first.name, 'T_Bkg_Act_001');
      expect(action[14].name, 'T_Bkg_Act_015');
    });

    test('folder name follows T_Bkg_<code> pattern', () {
      final kids = all.firstWhere((t) => t.genre == 'Kids');
      expect(kids.folder, 'T_Bkg_Kid');
      // "Kids" UI label maps to "Kid" code (Python remap, GENRE_DATATABLE).
      expect(kids.name.startsWith('T_Bkg_Kid_'), true);
    });

    test('every texture is typed Background in slice 1', () {
      expect(all.every((t) => t.type == 'Background'), true);
    });
  });
}
