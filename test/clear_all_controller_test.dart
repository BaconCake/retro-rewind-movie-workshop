import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/custom_slots_data_source.dart';
import 'package:rr_movie_workshop/data/datasources/nr_slots_data_source.dart';
import 'package:rr_movie_workshop/data/datasources/replacements_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';
import 'package:rr_movie_workshop/domain/entities/texture_replacement.dart';
import 'package:rr_movie_workshop/presentation/providers/providers.dart';

/// Coverage for [ClearAllController] — port of Python's `_clear_all_custom`
/// (RR_VHS_Tool.py:10814-10847).  Mirrors the same write-side guarantees:
/// genre slots, NR slots, replacements, and both tracking sets all wiped
/// in a single bulk pass.
void main() {
  group('ClearAllController.call', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_clearall_test_');
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

    test('returns 0 and does nothing on an empty library', () async {
      // No files seeded → load() returns empty for each data source.
      final removed =
          await container.read(clearAllControllerProvider).call();
      expect(removed, 0);

      // No write should have happened — files still absent.
      expect(File(p.join(tmp.path, 'custom_slots.json')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'nr_custom_slots.json')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'replacements.json')).existsSync(),
          isFalse);
    });

    test('clears genre slots, NR slots, and replacements', () async {
      await CustomSlotsDataSource(tmp.path).save({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'a',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
          const SlotData(
            bkgTex: 'T_Bkg_Dra_002',
            pnName: 'b',
            ls: 0,
            lsc: 4,
            sku: 2,
          ),
        ],
        'Horror': [
          const SlotData(
            bkgTex: 'T_Bkg_Hor_001',
            pnName: 'c',
            ls: 0,
            lsc: 4,
            sku: 3,
          ),
        ],
      });
      await NrSlotsDataSource(tmp.path).save([
        const NewReleaseSlot(
          bkgTex: 'T_New_Dra_001',
          title: 'nr1',
          genre: 'Drama',
          genreCode: 'Dra',
          sku: 51230093,
          genreByte: 0,
          texNum: 1,
          standeeShape: 'A',
        ),
        const NewReleaseSlot(
          bkgTex: 'T_New_Hor_001',
          title: 'nr2',
          genre: 'Horror',
          genreCode: 'Hor',
          sku: 51240093,
          genreByte: 1,
          texNum: 1,
          standeeShape: 'B',
        ),
      ]);
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Dra_001':
            const TextureReplacement(path: 'C:/cover1.png'),
        'T_New_Dra_001':
            const TextureReplacement(path: 'C:/cover2.png'),
      });

      final removed =
          await container.read(clearAllControllerProvider).call();

      // 3 genre + 2 NR = 5
      expect(removed, 5);
      expect(await CustomSlotsDataSource(tmp.path).load(), isEmpty);
      expect(await NrSlotsDataSource(tmp.path).load(), isEmpty);
      expect(await ReplacementsDataSource(tmp.path).load(), isEmpty);
    });

    test('clears edited + shipped tracking and deletes both files', () async {
      // Seed at least one slot so call() reaches the wipe path.
      await CustomSlotsDataSource(tmp.path).save({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'x',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });
      // Prime tracking via the notifier so state is populated.
      await container
          .read(trackingProvider.notifier)
          .markEdited('T_Bkg_Dra_001');
      await container
          .read(trackingProvider.notifier)
          .onBuildSuccess({'T_Bkg_Hor_999'}); // also touches shipped
      await container
          .read(trackingProvider.notifier)
          .markEdited('T_Bkg_Dra_001');

      // Pre-state: both tracking files exist on disk.
      expect(File(p.join(tmp.path, 'edited_slots.json')).existsSync(),
          isTrue);
      expect(File(p.join(tmp.path, 'shipped_slots.json')).existsSync(),
          isTrue);

      await container.read(clearAllControllerProvider).call();

      final tracking = container.read(trackingProvider);
      expect(tracking.edited, isEmpty);
      expect(tracking.shipped, isEmpty);
      expect(File(p.join(tmp.path, 'edited_slots.json')).existsSync(),
          isFalse);
      expect(File(p.join(tmp.path, 'shipped_slots.json')).existsSync(),
          isFalse);
    });

    test('clears the active selection', () async {
      await CustomSlotsDataSource(tmp.path).save({
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
      container.read(selectedSlotBkgProvider.notifier).state =
          'T_Bkg_Dra_001';

      await container.read(clearAllControllerProvider).call();

      expect(container.read(selectedSlotBkgProvider), isNull);
    });

    test('invalidates customSlots + nr + replacements providers', () async {
      await CustomSlotsDataSource(tmp.path).save({
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
      await NrSlotsDataSource(tmp.path).save([
        const NewReleaseSlot(
          bkgTex: 'T_New_Dra_001',
          title: 'nr',
          genre: 'Drama',
          genreCode: 'Dra',
          sku: 51230093,
          genreByte: 0,
          texNum: 1,
          standeeShape: 'A',
        ),
      ]);
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Dra_001':
            const TextureReplacement(path: 'C:/cover.png'),
      });

      // Prime caches.
      await container.read(customSlotsProvider.future);
      await container.read(nrSlotsProvider.future);
      await container.read(replacementsProvider.future);

      await container.read(clearAllControllerProvider).call();

      expect(await container.read(customSlotsProvider.future), isEmpty);
      expect(await container.read(nrSlotsProvider.future), isEmpty);
      expect(await container.read(replacementsProvider.future), isEmpty);
    });

    test('wipes .pasted_covers/ directory', () async {
      await CustomSlotsDataSource(tmp.path).save({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'x',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });
      // Seed the clipboard-paste staging dir with a fake PNG.
      final pastedDir = Directory(p.join(tmp.path, '.pasted_covers'));
      await pastedDir.create();
      await File(p.join(pastedDir.path, 'fake.png'))
          .writeAsBytes([0x89, 0x50, 0x4E, 0x47]);
      expect(pastedDir.existsSync(), isTrue);

      await container.read(clearAllControllerProvider).call();

      expect(pastedDir.existsSync(), isFalse);
    });

    test('missing .pasted_covers/ directory is not an error', () async {
      // Common case: user never used Ctrl+V, so the dir was never created.
      // The clear must still succeed end-to-end.
      await CustomSlotsDataSource(tmp.path).save({
        'Drama': [
          const SlotData(
            bkgTex: 'T_Bkg_Dra_001',
            pnName: 'x',
            ls: 0,
            lsc: 4,
            sku: 1,
          ),
        ],
      });
      expect(Directory(p.join(tmp.path, '.pasted_covers')).existsSync(),
          isFalse);

      final removed =
          await container.read(clearAllControllerProvider).call();
      expect(removed, 1);
    });
  });
}
