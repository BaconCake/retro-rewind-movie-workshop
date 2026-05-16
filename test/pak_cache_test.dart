import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/genres.dart';
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

    /// Write a current-version stamp into `<tmp>/.pak_cache/.tool_version`.
    /// Tests that pre-populate the cache and expect a cache hit must call
    /// this so the new stamp-invalidation logic doesn't wipe their fixtures.
    Future<void> primeStamp() async {
      final stampDir = Directory(p.join(tmp.path, '.pak_cache'));
      await stampDir.create(recursive: true);
      await File(p.join(stampDir.path, '.tool_version'))
          .writeAsString(kPakCacheStampVersion);
    }

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
      await primeStamp();

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
      await primeStamp();

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
      await primeStamp();

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

  // ── Tool-version stamp invalidation (A1) ─────────────────────────────────
  //
  // Pure port of PakCache._invalidate_stale_cache (RR_VHS_Tool.py:5644-5666).
  // The stamp lives at `<extractDir>/.tool_version`; mismatched/missing
  // stamps with existing content trigger a recursive wipe so a buggy
  // asset-rebuild from a prior tool version doesn't survive the next launch.
  group('PakCache tool-version stamp', () {
    late Directory tmp;
    late File fakeRepak;
    late File fakeBase;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_pakcache_stamp_test_');
      fakeRepak = File(p.join(tmp.path, 'fake_repak.exe'));
      await fakeRepak.writeAsBytes([0]);
      fakeBase = File(p.join(tmp.path, 'fake.pak'));
      await fakeBase.writeAsBytes([0]);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    AppConfig okConfig() => AppConfig(
          texconv: '',
          repak: fakeRepak.path,
          baseGamePak: fakeBase.path,
          modsFolder: '',
        );

    String stampPath() => p.join(tmp.path, '.pak_cache', '.tool_version');

    test('writes the current stamp on first run (empty workdir)', () async {
      // No .pak_cache/ yet — extraction will fail because repak is fake, but
      // the stamp must still be written so the next launch sees a fresh,
      // matching tool version.
      final cache = PakCache(tmp.path);
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');

      final stamp = File(stampPath());
      expect(await stamp.exists(), true,
          reason: 'stamp file must be created on first extract call');
      expect((await stamp.readAsString()).trim(), kPakCacheStampVersion);
    });

    test('matching stamp preserves cached content (cache hit survives)',
        () async {
      final cached = File(p.join(
          tmp.path, '.pak_cache', 'RetroRewind', 'AssetRegistry.bin'));
      await cached.create(recursive: true);
      await cached.writeAsBytes([1, 2, 3, 4]);
      await File(stampPath()).writeAsString(kPakCacheStampVersion);

      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
          okConfig(), 'RetroRewind/AssetRegistry.bin');

      expect(r.ok, true);
      expect(r.sizeBytes, 4);
      expect(await cached.exists(), true);
    });

    test('mismatched stamp wipes existing cache content', () async {
      final cached = File(p.join(
          tmp.path, '.pak_cache', 'RetroRewind', 'AssetRegistry.bin'));
      await cached.create(recursive: true);
      await cached.writeAsBytes([9, 9, 9]);
      await File(stampPath()).writeAsString('v0.0.0-ancient');

      final cache = PakCache(tmp.path);
      // Extraction will fail (fake repak) but the wipe must happen first.
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');

      expect(await cached.exists(), false,
          reason: 'stale cached file must be removed when stamp mismatches');
      // Fresh stamp written for the next launch.
      expect(await File(stampPath()).exists(), true);
      expect((await File(stampPath()).readAsString()).trim(),
          kPakCacheStampVersion);
    });

    test('missing stamp with cached content triggers wipe', () async {
      // Simulates the first launch of a stamp-aware tool version after a
      // previous (pre-stamp) version left files behind.  Python wipes.
      final cached = File(p.join(
          tmp.path, '.pak_cache', 'RetroRewind', 'AssetRegistry.bin'));
      await cached.create(recursive: true);
      await cached.writeAsBytes([42]);
      // No stamp file written.

      final cache = PakCache(tmp.path);
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');

      expect(await cached.exists(), false);
      expect(await File(stampPath()).exists(), true);
    });

    test('empty extract dir: stamp written without wipe', () async {
      // Pre-create just the .pak_cache/ folder (empty).  Python skips the
      // rmtree (matching `os.listdir(...) → []`) and writes the stamp.  Our
      // port should do the same — no spurious "wiping" log path.
      await Directory(p.join(tmp.path, '.pak_cache')).create(recursive: true);

      final cache = PakCache(tmp.path);
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');

      expect(await File(stampPath()).exists(), true);
    });

    test('validation runs once per instance (idempotent)', () async {
      // Two extract calls — only the first should care about the stamp.
      // After the first call the stamp is in place; the second sees a
      // matching stamp and short-circuits.
      final cache = PakCache(tmp.path);
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');
      // Tamper with the stamp behind the cache's back — should NOT trigger
      // a new wipe on the second call (validation is cached per instance).
      await File(stampPath()).writeAsString('v9.9.9-future');
      await cache.extractFile(okConfig(), 'RetroRewind/AssetRegistry.bin');

      expect((await File(stampPath()).readAsString()).trim(),
          'v9.9.9-future',
          reason: 'second call must not rewrite stamp (idempotent per '
              'instance — Python re-checks only on a new PakCache())');
    });

    test('config-error path does not touch the stamp', () async {
      // When _checkConfig fails (empty base pak), extractFile returns
      // before stamp validation — nothing in the workdir should exist.
      final cache = PakCache(tmp.path);
      final r = await cache.extractFile(
          const AppConfig.empty(), 'RetroRewind/AssetRegistry.bin');
      expect(r.ok, false);
      expect(await Directory(p.join(tmp.path, '.pak_cache')).exists(), false,
          reason: 'no .pak_cache/ should be created when config invalid');
    });
  });
}
