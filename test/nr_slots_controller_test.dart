import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/datasources/nr_slots_data_source.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';
import 'package:rr_movie_workshop/presentation/providers/providers.dart';

/// Coverage for the NR-side timestamp wiring added 2026-05-12.
///
/// `NrSlotsController.updateSlot` now bumps `lastEditedAt`, matching the
/// Python tool's `_flush_pending_nr_timestamp` (RR_VHS_Tool.py:7826-7845)
/// and keeping sort behaviour symmetrical with `SlotsController`.
void main() {
  // Python `_now_iso()` format: YYYY-MM-DDTHH:MM:SS — local time, no
  // microseconds, no timezone suffix.
  final iso = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$');

  NewReleaseSlot seedSlot({
    String? createdAt,
    String? lastEditedAt,
    String bkgTex = 'T_New_Dra_001',
    String genre = 'Drama',
    String genreCode = 'Dra',
    int genreByte = 4,
    int sku = 51001,
  }) =>
      NewReleaseSlot(
        title: 'nr1',
        genre: genre,
        genreCode: genreCode,
        genreByte: genreByte,
        bkgTex: bkgTex,
        sku: sku,
        standeeShape: 'A',
        texNum: 1,
        createdAt: createdAt,
        lastEditedAt: lastEditedAt,
      );

  group('NrSlotsController.updateSlot', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_nr_ts_test_');
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

    Future<List<NewReleaseSlot>> read() =>
        NrSlotsDataSource(tmp.path).load();

    test('bumps lastEditedAt on every commit, preserves createdAt',
        () async {
      await NrSlotsDataSource(tmp.path).save([
        seedSlot(createdAt: '2026-05-01T10:00:00'),
      ]);

      final loaded = (await read()).single;
      await container
          .read(nrSlotsControllerProvider)
          .updateSlot(loaded.copyWith(title: 'renamed'));

      final after = (await read()).single;
      expect(after.title, 'renamed');
      expect(after.createdAt, '2026-05-01T10:00:00',
          reason: 'createdAt must never change after creation');
      expect(after.lastEditedAt, matches(iso),
          reason: 'lastEditedAt must be stamped in Python _now_iso format');
    });

    test('no-op when SKU does not match (file untouched)', () async {
      await NrSlotsDataSource(tmp.path).save([seedSlot(sku: 51001)]);
      final mtimeBefore = await File(
              '${tmp.path}/nr_custom_slots.json')
          .lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await container
          .read(nrSlotsControllerProvider)
          .updateSlot(seedSlot(sku: 59999, bkgTex: 'T_New_Dra_002'));

      expect(
          await File('${tmp.path}/nr_custom_slots.json').lastModified(),
          mtimeBefore);
    });
  });

  group('NrSlotsController.touchEditTime', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_nr_touch_test_');
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

    Future<List<NewReleaseSlot>> read() =>
        NrSlotsDataSource(tmp.path).load();

    test('stamps lastEditedAt on the matching bkgTex', () async {
      await NrSlotsDataSource(tmp.path).save([
        seedSlot(createdAt: '2026-05-01T10:00:00'),
      ]);

      await container
          .read(nrSlotsControllerProvider)
          .touchEditTime('T_New_Dra_001');

      final after = (await read()).single;
      expect(after.createdAt, '2026-05-01T10:00:00');
      expect(after.lastEditedAt, matches(iso));
    });

    test('no-op for unknown bkgTex (e.g. genre slot bkgTex)', () async {
      await NrSlotsDataSource(tmp.path).save([seedSlot()]);
      final before = await File('${tmp.path}/nr_custom_slots.json')
          .readAsString();

      await container
          .read(nrSlotsControllerProvider)
          .touchEditTime('T_Bkg_Dra_001');

      expect(
          await File('${tmp.path}/nr_custom_slots.json').readAsString(),
          before,
          reason:
              'Genre bkgTex must not rewrite nr_custom_slots.json — '
              'the symmetric SlotsController.touchEditTime handles it.');
    });

    test('called by ReplacementsController.setImage when bkgTex is an NR',
        () async {
      await NrSlotsDataSource(tmp.path).save([
        seedSlot(createdAt: '2026-05-01T10:00:00'),
      ]);

      await container
          .read(replacementsControllerProvider)
          .setImage('T_New_Dra_001', 'C:/some/cover.png');

      final after = (await read()).single;
      expect(after.lastEditedAt, matches(iso),
          reason: 'setImage on a T_New bkgTex must touch the NR slot');
    });
  });
}
