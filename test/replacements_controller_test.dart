import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/replacements_data_source.dart';
import 'package:rr_movie_workshop/domain/entities/texture_replacement.dart';
import 'package:rr_movie_workshop/presentation/providers/providers.dart';

/// Coverage gap relative to the Python tool: there is no equivalent of this
/// mutation flow in the Python source — Python uses Tk dialogs that bypass
/// any controller layer.  These tests pin the Dart controller's behaviour
/// (preserve metadata, no-op on remove-when-absent, file written atomically)
/// so future refactors can't silently lose a user's offset/zoom edits.
void main() {
  group('ReplacementsController', () {
    late Directory tmp;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_repl_ctrl_test_');
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

    String filePath() => p.join(tmp.path, 'replacements.json');

    Future<Map<String, TextureReplacement>> read() =>
        ReplacementsDataSource(tmp.path).load();

    test('setImage creates the file when none exists', () async {
      expect(File(filePath()).existsSync(), isFalse);

      await container
          .read(replacementsControllerProvider)
          .setImage('T_Bkg_Hor_001', 'C:/img.png');

      final loaded = await read();
      expect(loaded.keys, ['T_Bkg_Hor_001']);
      expect(loaded['T_Bkg_Hor_001']!.path, 'C:/img.png');
      expect(loaded['T_Bkg_Hor_001']!.offsetX, 0);
      expect(loaded['T_Bkg_Hor_001']!.zoom, 1.0);
    });

    test('setImage preserves existing offsetX/offsetY/zoom on path change',
        () async {
      // Seed the file with a fully-specified entry — exactly the shape Python
      // writes when the user has tweaked the offsets/zoom via the cropper.
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Wst_001': const TextureReplacement(
          path: 'C:/old.jpg',
          offsetX: 17,
          offsetY: -197,
          zoom: 0.778,
        ),
      });

      await container
          .read(replacementsControllerProvider)
          .setImage('T_Bkg_Wst_001', 'C:/new.jpg');

      final loaded = await read();
      final entry = loaded['T_Bkg_Wst_001']!;
      expect(entry.path, 'C:/new.jpg');
      expect(entry.offsetX, 17);
      expect(entry.offsetY, -197);
      expect(entry.zoom, closeTo(0.778, 1e-9));
    });

    test('setImage leaves other slots untouched', () async {
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Hor_001': const TextureReplacement(path: 'C:/keep.png'),
        'T_Bkg_Adu_001': const TextureReplacement(path: 'C:/also-keep.png'),
      });

      await container
          .read(replacementsControllerProvider)
          .setImage('T_Bkg_Adu_001', 'C:/changed.png');

      final loaded = await read();
      expect(loaded['T_Bkg_Hor_001']!.path, 'C:/keep.png');
      expect(loaded['T_Bkg_Adu_001']!.path, 'C:/changed.png');
    });

    test('removeImage deletes the entry and writes the file', () async {
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Hor_001': const TextureReplacement(path: 'C:/a.png'),
        'T_Bkg_Adu_001': const TextureReplacement(path: 'C:/b.png'),
      });

      await container
          .read(replacementsControllerProvider)
          .removeImage('T_Bkg_Hor_001');

      final loaded = await read();
      expect(loaded.keys, ['T_Bkg_Adu_001']);
    });

    test('removeImage is a no-op when the slot has no entry', () async {
      // No file at all — the controller must not crash and must not write
      // an empty file (we don't want to materialise replacements.json on a
      // misclick).
      await container
          .read(replacementsControllerProvider)
          .removeImage('T_Bkg_Hor_001');

      expect(File(filePath()).existsSync(), isFalse);
    });

    test('setImage invalidates replacementsProvider so reads see the new value',
        () async {
      // Force first read so the FutureProvider caches an empty map.
      await container.read(replacementsProvider.future);

      await container
          .read(replacementsControllerProvider)
          .setImage('T_Bkg_Hor_001', 'C:/img.png');

      final next = await container.read(replacementsProvider.future);
      expect(next['T_Bkg_Hor_001']!.path, 'C:/img.png');
    });

    test('setTransform updates offsets + zoom, leaves the image path alone',
        () async {
      await ReplacementsDataSource(tmp.path).save({
        'T_Bkg_Wst_001': const TextureReplacement(
          path: 'C:/poster.jpg',
          offsetX: 0,
          offsetY: 0,
          zoom: 1.0,
        ),
      });

      await container.read(replacementsControllerProvider).setTransform(
            'T_Bkg_Wst_001',
            offsetX: 17,
            offsetY: -197,
            zoom: 0.778,
          );

      final loaded = await read();
      final entry = loaded['T_Bkg_Wst_001']!;
      expect(entry.path, 'C:/poster.jpg'); // image untouched
      expect(entry.offsetX, 17);
      expect(entry.offsetY, -197);
      expect(entry.zoom, closeTo(0.778, 1e-9));
    });

    test('setTransform is a no-op when the slot has no replacement', () async {
      // No file at all — must not crash and must not materialise an entry
      // (transform without a path makes no sense).
      await container.read(replacementsControllerProvider).setTransform(
            'T_Bkg_Hor_001',
            offsetX: 5,
            offsetY: 5,
            zoom: 1.5,
          );
      expect(File(filePath()).existsSync(), isFalse);
    });
  });
}
