import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/domain/entities/texture_replacement.dart';
import 'package:rr_movie_workshop/domain/replacements_migration.dart';

TextureReplacement _r(String path) =>
    TextureReplacement(path: path, offsetX: 0, offsetY: 0, zoom: 1.0);

void main() {
  group('applyReplacementsKeyMigration', () {
    test('2-digit T_New key is rewritten to 3-digit', () {
      final r = applyReplacementsKeyMigration({
        'T_New_Dra_05': _r('drama-5.png'),
      });
      expect(r.migrated, 1);
      expect(r.entries.keys, ['T_New_Dra_005']);
      expect(r.entries['T_New_Dra_005']?.path, 'drama-5.png');
    });

    test('2-digit T_Bkg key is rewritten to 3-digit', () {
      final r = applyReplacementsKeyMigration({
        'T_Bkg_Hor_20': _r('horror-20.png'),
      });
      expect(r.migrated, 1);
      expect(r.entries.keys, ['T_Bkg_Hor_020']);
    });

    test('1-digit slot number (single char) is rewritten to 3-digit', () {
      // _remap_slot_to_3digit handles numPart shorter than 3 chars, not
      // just == 2.  A "T_Bkg_Hor_5" shape should still migrate.
      final r = applyReplacementsKeyMigration({
        'T_Bkg_Hor_5': _r('horror-5.png'),
      });
      expect(r.migrated, 1);
      expect(r.entries.keys, ['T_Bkg_Hor_005']);
    });

    test('already-3-digit keys are passed through unchanged', () {
      final r = applyReplacementsKeyMigration({
        'T_New_Dra_005': _r('drama-5.png'),
        'T_Bkg_Hor_020': _r('horror-20.png'),
      });
      expect(r.migrated, 0);
      expect(r.entries.keys.toSet(), {'T_New_Dra_005', 'T_Bkg_Hor_020'});
    });

    test('non-T_Bkg / non-T_New keys are passed through (NR_<sku>, custom)',
        () {
      final r = applyReplacementsKeyMigration({
        'NR_58004': _r('a.png'),
        'something_unrelated': _r('b.png'),
      });
      expect(r.migrated, 0);
      expect(r.entries.keys.toSet(), {'NR_58004', 'something_unrelated'});
    });

    test('malformed keys (non-numeric tail) are left alone', () {
      final r = applyReplacementsKeyMigration({
        'T_Bkg_Hor_abc': _r('x.png'),
        'T_New_Dra': _r('y.png'),
      });
      expect(r.migrated, 0);
      expect(r.entries.keys.toSet(), {'T_Bkg_Hor_abc', 'T_New_Dra'});
    });

    test('mixed input migrates only the 2-digit entries', () {
      final r = applyReplacementsKeyMigration({
        'T_New_Dra_05': _r('a.png'),        // migrate
        'T_New_Dra_005': _r('b.png'),       // already-3-digit
        'T_Bkg_Hor_07': _r('c.png'),        // migrate
        'NR_58004': _r('d.png'),            // not migrated
      });
      expect(r.migrated, 2);
      expect(
        r.entries.keys.toSet(),
        {'T_New_Dra_005', 'T_Bkg_Hor_007', 'NR_58004'},
        reason: 'T_New_Dra_05 collides with already-3-digit T_New_Dra_005; '
            'later-write wins per dict-order policy',
      );
    });

    test('collision: 3-digit entry written after legacy 2-digit wins', () {
      // Insertion order: legacy first, then new.  Migration rewrites the
      // legacy key to the same target as the new entry; the new entry's
      // write comes last → new entry survives.  Matches Python's dict-
      // order behaviour and the realistic user history (legacy keys are
      // older, 3-digit keys were written after upgrade).
      final input = <String, TextureReplacement>{
        'T_New_Hor_03': _r('legacy.png'),
        'T_New_Hor_003': _r('new.png'),
      };
      final r = applyReplacementsKeyMigration(input);
      expect(r.entries['T_New_Hor_003']?.path, 'new.png');
      expect(r.entries.keys, ['T_New_Hor_003']);
    });

    test('empty map yields empty map with migrated=0', () {
      final r = applyReplacementsKeyMigration({});
      expect(r.migrated, 0);
      expect(r.entries, isEmpty);
    });
  });
}
