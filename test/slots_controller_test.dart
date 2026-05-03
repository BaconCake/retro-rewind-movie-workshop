import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/genres.dart';
import 'package:rr_movie_workshop/data/datasources/custom_slots_data_source.dart';
import 'package:rr_movie_workshop/data/datasources/replacements_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';
import 'package:rr_movie_workshop/domain/entities/texture_replacement.dart';
import 'package:rr_movie_workshop/domain/sku.dart';
import 'package:rr_movie_workshop/presentation/providers/providers.dart';

/// Same coverage-gap rationale as `replacements_controller_test.dart`:
/// the Python tool does not have an equivalent controller layer (Tk
/// dialogs mutate dicts directly), so these tests fence in the Dart
/// behaviour against future regressions.
void main() {
  group('SlotsController.updateSlot', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_slots_ctrl_test_');
      container = ProviderContainer(overrides: [
        workingDirProvider.overrideWithValue(tmp.path),
      ]);
    });

    tearDown(() async {
      container.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best-effort */}
    });

    Future<void> seed(Map<String, List<SlotData>> data) =>
        CustomSlotsDataSource(tmp.path).save(data);

    Future<Map<String, List<SlotData>>> read() =>
        CustomSlotsDataSource(tmp.path).load();

    test('replaces the matching slot in place, leaving siblings untouched',
        () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'Old Name',
            ls: 0,
            lsc: 4,
            sku: 40200012,
            subTex: 'T_Sub_78',
          ),
          const SlotData(
            bkgTex: 'T_Bkg_Dra_002',
            pnName: 'Other',
            ls: 0,
            lsc: 4,
            sku: 40200013,
          ),
        ],
      });

      await container.read(slotsControllerProvider).updateSlot(
            const SlotData(
              bkgTex: 'T_Bkg_Dra_001',
              pnName: 'New Name',
              ls: 3,
              lsc: 7,
              sku: 99999999,
              ntu: true,
              subTex: 'T_Sub_78',
            ),
          );

      final loaded = await read();
      expect(loaded['Drama'], hasLength(2));
      // Order preserved.
      expect(loaded['Drama']![0].bkgTex, 'T_Bkg_Dra_001');
      expect(loaded['Drama']![1].bkgTex, 'T_Bkg_Dra_002');
      // Edited fields applied.
      expect(loaded['Drama']![0].pnName, 'New Name');
      expect(loaded['Drama']![0].ls, 3);
      expect(loaded['Drama']![0].lsc, 7);
      expect(loaded['Drama']![0].sku, 99999999);
      expect(loaded['Drama']![0].ntu, isTrue);
      // Sibling untouched.
      expect(loaded['Drama']![1].pnName, 'Other');
      expect(loaded['Drama']![1].sku, 40200013);
    });

    test('finds the slot across genres (bkgTex is globally unique)', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
        'Adult': [
          const SlotData(
            bkgTex: 'T_Bkg_Adu_001',
            pnName: 'b',
            ls: 0,
            lsc: 4,
            sku: 2,
          ),
        ],
      });

      await container.read(slotsControllerProvider).updateSlot(
            const SlotData(
              bkgTex: 'T_Bkg_Adu_001',
              pnName: 'b-edited',
              ls: 0,
              lsc: 4,
              sku: 2,
            ),
          );

      final loaded = await read();
      expect(loaded['Drama']!.single.pnName, 'a');
      expect(loaded['Adult']!.single.pnName, 'b-edited');
    });

    test('no-ops when the slot does not exist (does not write garbage)',
        () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });

      // Snapshot file content + mtime so we can verify save() was not called.
      final f = File(p.join(tmp.path, 'custom_slots.json'));
      final before = await f.readAsString();
      final mtimeBefore = await f.lastModified();

      await Future<void>.delayed(const Duration(milliseconds: 10));

      await container.read(slotsControllerProvider).updateSlot(
            const SlotData(
              bkgTex: 'T_Bkg_Hor_999',
              pnName: 'ghost',
              ls: 0,
              lsc: 4,
              sku: 0,
            ),
          );

      expect(await f.readAsString(), before);
      expect(await f.lastModified(), mtimeBefore);
    });

    test('persisted JSON omits sub_tex when null', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });

      await container.read(slotsControllerProvider).updateSlot(
            const SlotData(
              bkgTex: 'T_Bkg_Dra_001',
              pnName: 'a',
              ls: 0,
              lsc: 4,
              sku: 1,
              // subTex omitted on purpose.
            ),
          );

      final raw =
          await File(p.join(tmp.path, 'custom_slots.json')).readAsString();
      expect(raw.contains('sub_tex'), isFalse);
    });

    test('updateSlot invalidates customSlotsProvider', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'before',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });

      // Prime the cache.
      await container.read(customSlotsProvider.future);

      await container.read(slotsControllerProvider).updateSlot(
            const SlotData(
              bkgTex: 'T_Bkg_Dra_001',
              pnName: 'after',
              ls: 0,
              lsc: 4,
              sku: 1,
            ),
          );

      final next = await container.read(customSlotsProvider.future);
      expect(next['Drama']!.single.pnName, 'after');
    });
  });

  group('SlotsController.addSlot', () {
    late Directory tmp;
    late ProviderContainer container;

    GenreInfo drama() => kGenres.firstWhere((g) => g.name == 'Drama');
    GenreInfo adventure() => kGenres.firstWhere((g) => g.name == 'Adventure');

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_addslot_test_');
      container = ProviderContainer(overrides: [
        workingDirProvider.overrideWithValue(tmp.path),
      ]);
    });

    tearDown(() async {
      container.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best-effort */}
    });

    Future<void> seed(Map<String, List<SlotData>> data) =>
        CustomSlotsDataSource(tmp.path).save(data);
    Future<Map<String, List<SlotData>>> read() =>
        CustomSlotsDataSource(tmp.path).load();

    test('first add starts at T_Bkg_Dra_001 / T_Sub_78', () async {
      final tex = await container
          .read(slotsControllerProvider)
          .addSlot(genre: drama(), title: 'My First');
      expect(tex, 'T_Bkg_Dra_001');

      final loaded = await read();
      expect(loaded['Drama'], hasLength(1));
      final s = loaded['Drama']!.single;
      expect(s.bkgTex, 'T_Bkg_Dra_001');
      expect(s.subTex, 'T_Sub_78');
      expect(s.pnName, 'My First');
      expect(s.ls, 0);
      expect(s.lsc, 4);
      // SKU was generated → has Drama prefix (4) and last2=93 (default 4.5★).
      expect(s.sku ~/ 10000000, 4);
      expect(s.sku % 100, 93);
    });

    test('subsequent adds get sequential T_Sub_NN', () async {
      final ctrl = container.read(slotsControllerProvider);
      await ctrl.addSlot(genre: drama(), title: 'a');
      await ctrl.addSlot(genre: drama(), title: 'b');
      await ctrl.addSlot(genre: drama(), title: 'c');

      final loaded = await read();
      expect(loaded['Drama']!.map((s) => s.bkgTex).toList(), [
        'T_Bkg_Dra_001',
        'T_Bkg_Dra_002',
        'T_Bkg_Dra_003',
      ]);
      expect(loaded['Drama']!.map((s) => s.subTex).toList(), [
        'T_Sub_78',
        'T_Sub_79',
        'T_Sub_80',
      ]);
    });

    test('add fills the lowest gap left by a delete', () async {
      // Seed two slots, then a third manually with a higher index, then
      // delete the middle one. New add should land in the freed slot.
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 41000093,
            subTex: 'T_Sub_78',
          ),
          const SlotData(
            bkgTex: 'T_Bkg_Dra_003',
            pnName: 'c',
            ls: 0,
            lsc: 4,
            sku: 41030093,
            subTex: 'T_Sub_80',
          ),
        ],
      });
      final tex = await container
          .read(slotsControllerProvider)
          .addSlot(genre: drama(), title: 'b');
      expect(tex, 'T_Bkg_Dra_002');
    });

    test('Hidden genre (Adventure) is rejected', () async {
      final tex = await container
          .read(slotsControllerProvider)
          .addSlot(genre: adventure(), title: 'no');
      expect(tex, isNull);

      final loaded = await read();
      expect(loaded.containsKey('Adventure'), isFalse);
    });

    test('respects star rating + rarity in the generated SKU', () async {
      final tex = await container.read(slotsControllerProvider).addSlot(
            genre: drama(),
            title: 'limited movie',
            last2: 0, // 5.0★
            rarity: Rarity.limited,
          );
      expect(tex, isNotNull);

      final loaded = await read();
      final s = loaded['Drama']!.single;
      expect(s.sku % 100, 0);
      expect(skuIsHolo(s.sku), isTrue);
    });

    test('addSlot invalidates customSlotsProvider', () async {
      await container.read(customSlotsProvider.future); // prime cache
      await container
          .read(slotsControllerProvider)
          .addSlot(genre: drama(), title: 'fresh');
      final next = await container.read(customSlotsProvider.future);
      expect(next['Drama']!.single.pnName, 'fresh');
    });
  });

  group('SlotsController.removeSlot', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_rmslot_test_');
      container = ProviderContainer(overrides: [
        workingDirProvider.overrideWithValue(tmp.path),
      ]);
    });

    tearDown(() async {
      container.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best-effort */}
    });

    Future<void> seed(Map<String, List<SlotData>> data) =>
        CustomSlotsDataSource(tmp.path).save(data);
    Future<Map<String, List<SlotData>>> read() =>
        CustomSlotsDataSource(tmp.path).load();

    test('removes the matching slot, keeps siblings', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'keep',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
          const SlotData(
            bkgTex: 'T_Bkg_Dra_002',
            pnName: 'drop',
            ls: 0,
            lsc: 4,
            sku: 2,
          ),
        ],
      });

      await container
          .read(slotsControllerProvider)
          .removeSlot('T_Bkg_Dra_002');

      final loaded = await read();
      expect(loaded['Drama'], hasLength(1));
      expect(loaded['Drama']!.single.pnName, 'keep');
    });

    test('also drops the matching replacements.json entry', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Dra_001':
            const TextureReplacement(path: 'C:/some/cover.png'),
        'T_Bkg_Hor_001':
            const TextureReplacement(path: 'C:/keep.png'),
      });

      await container
          .read(slotsControllerProvider)
          .removeSlot('T_Bkg_Dra_001');

      final repl = await ReplacementsDataSource(tmp.path).load();
      expect(repl.containsKey('T_Bkg_Dra_001'), isFalse);
      expect(repl.containsKey('T_Bkg_Hor_001'), isTrue);
    });

    test('no-op when the slot does not exist (file untouched)', () async {
      await seed({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });
      final f = File(p.join(tmp.path, 'custom_slots.json'));
      final before = await f.readAsString();
      final mtimeBefore = await f.lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await container
          .read(slotsControllerProvider)
          .removeSlot('T_Bkg_Hor_999');

      expect(await f.readAsString(), before);
      expect(await f.lastModified(), mtimeBefore);
    });
  });
}
