import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/custom_slots_data_source.dart';

void main() {
  group('CustomSlotsDataSource.load', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_custom_slots_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best-effort */}
    });

    Future<void> writeJson(String contents) {
      return File(p.join(tmp.path, 'custom_slots.json')).writeAsString(contents);
    }

    test('returns an empty map when the file does not exist', () async {
      final ds = CustomSlotsDataSource(tmp.path);
      expect(await ds.load(), isEmpty);
    });

    test('returns an empty map when the file is empty / whitespace', () async {
      await writeJson('   \n  ');
      final ds = CustomSlotsDataSource(tmp.path);
      expect(await ds.load(), isEmpty);
    });

    test('parses the production custom_slots.json shape', () async {
      // Same shape as the user's actual custom_slots.json on the home PC.
      await writeJson('''
        {
          "Drama": [
            {
              "bkg_tex": "T_Bkg_Dra_001",
              "sub_tex": "T_Sub_78",
              "pn_name": "My Custom Movie",
              "ls": 0,
              "lsc": 4,
              "sku": 40200012,
              "ntu": false
            }
          ],
          "Adult": [
            {
              "bkg_tex": "T_Bkg_Adu_001",
              "sub_tex": "T_Sub_78",
              "pn_name": "adam",
              "ls": 0,
              "lsc": 4,
              "sku": 690010093,
              "ntu": false
            },
            {
              "bkg_tex": "T_Bkg_Adu_002",
              "sub_tex": "T_Sub_79",
              "pn_name": "eve",
              "ls": 0,
              "lsc": 4,
              "sku": 690020093,
              "ntu": false
            }
          ]
        }
      ''');

      final result = await CustomSlotsDataSource(tmp.path).load();

      expect(result.keys, containsAll(['Drama', 'Adult']));
      expect(result['Drama']!, hasLength(1));
      expect(result['Drama']!.single.bkgTex, 'T_Bkg_Dra_001');
      expect(result['Drama']!.single.pnName, 'My Custom Movie');
      expect(result['Drama']!.single.sku, 40200012);

      expect(result['Adult']!, hasLength(2));
      expect(
          result['Adult']!.map((s) => s.bkgTex).toList(),
          ['T_Bkg_Adu_001', 'T_Bkg_Adu_002']);
      expect(result['Adult']!.last.pnName, 'eve');
    });

    test('skips malformed entries inside an otherwise-valid genre', () async {
      // First entry valid, second missing pn_name → keep entry 1, drop entry 2.
      // We don't want a single bad row to nuke the whole file.
      await writeJson('''
        {
          "Drama": [
            {"bkg_tex": "T_Bkg_Dra_001", "pn_name": "ok"},
            {"bkg_tex": "T_Bkg_Dra_002"}
          ]
        }
      ''');
      final result = await CustomSlotsDataSource(tmp.path).load();
      expect(result['Drama']!, hasLength(1));
      expect(result['Drama']!.single.bkgTex, 'T_Bkg_Dra_001');
    });

    test('drops genres whose value is not a list', () async {
      await writeJson('{"Drama": "not a list", "Adult": [{"bkg_tex":"T_Bkg_Adu_001","pn_name":"x"}]}');
      final result = await CustomSlotsDataSource(tmp.path).load();
      expect(result.keys, ['Adult']);
    });

    test('throws on a non-object root (caller treats as empty)', () async {
      await writeJson('[]');
      expect(() => CustomSlotsDataSource(tmp.path).load(),
          throwsFormatException);
    });
  });
}
