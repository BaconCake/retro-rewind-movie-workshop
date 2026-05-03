import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

void main() {
  group('PakCache (no real pak required)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_pakcache_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    AppConfig cfg({String repak = '', String basePak = ''}) => AppConfig(
          texconv: '',
          repak: repak,
          baseGamePak: basePak,
          modsFolder: '',
        );

    test('extractFile skips when base_game_pak is empty', () async {
      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
          const AppConfig.empty(), 'RetroRewind/AssetRegistry.bin');
      expect(r.ok, false);
      expect(r.warning, contains('base_game_pak'));
    });

    test('extractFile skips when base_game_pak path is missing on disk',
        () async {
      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
        cfg(repak: 'C:/x/repak.exe', basePak: 'C:/x/missing.pak'),
        'RetroRewind/AssetRegistry.bin',
      );
      expect(r.ok, false);
      expect(r.warning, contains('base_game_pak'));
    });

    test('extractFile skips when repak path is missing', () async {
      final fakeBase = File(p.join(tmp.path, 'fake.pak'));
      await fakeBase.writeAsBytes([0]);
      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
        cfg(repak: '', basePak: fakeBase.path),
        'RetroRewind/AssetRegistry.bin',
      );
      expect(r.ok, false);
      expect(r.warning, contains('repak.exe'));
    });

    test('extractFile cache hit short-circuits the repak invocation',
        () async {
      // Pre-populate cache with the file we'd normally extract.
      final cached = File(p.join(
          tmp.path, '.pak_cache', 'RetroRewind', 'AssetRegistry.bin'));
      await cached.create(recursive: true);
      final payload = List<int>.generate(256, (i) => i & 0xFF);
      await cached.writeAsBytes(payload);

      // Configure with bogus repak path — if cache is consulted, this is
      // never invoked. (Real existence-check happens up front, so we use
      // an existing dummy file as the repak binary.)
      final fakeRepak = File(p.join(tmp.path, 'fake_repak.exe'));
      await fakeRepak.writeAsBytes([0]);
      final fakeBase = File(p.join(tmp.path, 'fake.pak'));
      await fakeBase.writeAsBytes([0]);

      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
        cfg(repak: fakeRepak.path, basePak: fakeBase.path),
        'RetroRewind/AssetRegistry.bin',
      );
      expect(r.ok, true);
      expect(r.path, cached.path);
      expect(r.sizeBytes, payload.length);
    });

    test('readFile returns the cached bytes', () async {
      final cached = File(
          p.join(tmp.path, '.pak_cache', 'RetroRewind', 'AssetRegistry.bin'));
      await cached.create(recursive: true);
      final payload = List<int>.generate(64, (i) => (i * 3) & 0xFF);
      await cached.writeAsBytes(payload);

      final fakeRepak = File(p.join(tmp.path, 'fake_repak.exe'));
      await fakeRepak.writeAsBytes([0]);
      final fakeBase = File(p.join(tmp.path, 'fake.pak'));
      await fakeBase.writeAsBytes([0]);

      final cache = PakCache(tmp.path);
      final bytes = await cache.readFile(
        cfg(repak: fakeRepak.path, basePak: fakeBase.path),
        'RetroRewind/AssetRegistry.bin',
      );
      expect(bytes, isNotNull);
      expect(bytes, payload);
    });

    test('extractFolder cache hit returns the cached folder root', () async {
      // Pre-populate the folder so the cache check passes.
      final folder = Directory(p.join(
          tmp.path, '.pak_cache', 'RetroRewind', 'Content', 'foo'));
      await folder.create(recursive: true);
      await File(p.join(folder.path, 'a.uasset')).writeAsBytes([1, 2, 3]);

      final fakeRepak = File(p.join(tmp.path, 'fake_repak.exe'));
      await fakeRepak.writeAsBytes([0]);
      final fakeBase = File(p.join(tmp.path, 'fake.pak'));
      await fakeBase.writeAsBytes([0]);

      final cache = PakCache(tmp.path);
      final r = await cache.extractFolder(
        cfg(repak: fakeRepak.path, basePak: fakeBase.path),
        'RetroRewind/Content/foo/',
      );
      expect(r.ok, true);
      expect(r.path, folder.path);
    });

    test('extractDir is <workingDir>/.pak_cache (matches Python layout)', () {
      final cache = PakCache(tmp.path);
      expect(cache.extractDir, p.join(tmp.path, '.pak_cache'));
    });
  });
}
