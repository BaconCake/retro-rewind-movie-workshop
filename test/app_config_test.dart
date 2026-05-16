import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

void main() {
  group('AppConfig.isReady', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_appconfig_isready_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('empty config is not ready', () {
      expect(const AppConfig.empty().isReady, isFalse);
    });

    test('all four real paths with correct basenames → ready', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: tx.path,
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      expect(cfg.isReady, isTrue);
    });

    test('texconv field pointing at repak.exe → not ready', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');

      // Swap texconv and repak — both files exist, but the basenames are wrong.
      final cfg = AppConfig(
        texconv: rp.path,
        repak: tx.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      expect(cfg.isReady, isFalse);
    });

    test('base pak with arbitrary name → not ready', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, 'random.pak'));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: tx.path,
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      expect(cfg.isReady, isFalse,
          reason: 'base pak must be named $kBaseGamePakBasename');
    });

    test('one missing tool → not ready', () async {
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: p.join(tmp.path, 'texconv.exe'), // file doesn't exist
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      expect(cfg.isReady, isFalse);
    });

    test('mods_folder pointing at a regular file → not ready', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final notADir = File(p.join(tmp.path, '~mods'));
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');
      await notADir.writeAsString('');

      final cfg = AppConfig(
        texconv: tx.path,
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: notADir.path,
      );
      expect(cfg.isReady, isFalse);
    });

    test('empty modsFolder string → not ready', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: tx.path,
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: '',
      );
      expect(cfg.isReady, isFalse);
    });
  });

  group('AppConfig.withClearedStalePaths (H1)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_appconfig_stale_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('preserves real paths verbatim', () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await tx.writeAsString('');
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: tx.path,
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      final cleaned = cfg.withClearedStalePaths();
      expect(cleaned.texconv, tx.path);
      expect(cleaned.repak, rp.path);
      expect(cleaned.baseGamePak, pk.path);
      expect(cleaned.modsFolder, mods.path);
    });

    test('clears a path whose file no longer exists', () async {
      final rp = File(p.join(tmp.path, kRepakBasename));
      final pk = File(p.join(tmp.path, kBaseGamePakBasename));
      final mods = await Directory(p.join(tmp.path, '~mods')).create();
      await rp.writeAsString('');
      await pk.writeAsString('');

      final cfg = AppConfig(
        texconv: p.join(tmp.path, 'missing-texconv.exe'),
        repak: rp.path,
        baseGamePak: pk.path,
        modsFolder: mods.path,
      );
      final cleaned = cfg.withClearedStalePaths();
      expect(cleaned.texconv, isEmpty,
          reason: 'stale texconv path must be wiped');
      expect(cleaned.repak, rp.path);
      expect(cleaned.baseGamePak, pk.path);
      expect(cleaned.modsFolder, mods.path);
    });

    test('clears a mods folder that no longer exists', () async {
      final cfg = AppConfig(
        texconv: '',
        repak: '',
        baseGamePak: '',
        modsFolder: p.join(tmp.path, 'never-created'),
      );
      expect(cfg.withClearedStalePaths().modsFolder, isEmpty);
    });

    test('clears a mods folder that points at a regular file', () async {
      final notADir = File(p.join(tmp.path, '~mods'));
      await notADir.writeAsString('');
      final cfg = AppConfig(
        texconv: '',
        repak: '',
        baseGamePak: '',
        modsFolder: notADir.path,
      );
      expect(cfg.withClearedStalePaths().modsFolder, isEmpty,
          reason: 'a file at the mods_folder path is not a directory');
    });

    test('empty fields pass through unchanged (no false clearing)', () {
      const cfg = AppConfig.empty();
      expect(cfg.withClearedStalePaths(), isNot(same(cfg)));
      expect(cfg.withClearedStalePaths().texconv, isEmpty);
      expect(cfg.withClearedStalePaths().repak, isEmpty);
      expect(cfg.withClearedStalePaths().baseGamePak, isEmpty);
      expect(cfg.withClearedStalePaths().modsFolder, isEmpty);
    });

    test('mixed valid/invalid paths — only the invalid ones clear',
        () async {
      final tx = File(p.join(tmp.path, kTexconvBasename));
      await tx.writeAsString('');
      final cfg = AppConfig(
        texconv: tx.path,
        repak: p.join(tmp.path, 'no-repak.exe'),
        baseGamePak: p.join(tmp.path, 'no-pak.pak'),
        modsFolder: p.join(tmp.path, 'no-mods'),
      );
      final cleaned = cfg.withClearedStalePaths();
      expect(cleaned.texconv, tx.path);
      expect(cleaned.repak, isEmpty);
      expect(cleaned.baseGamePak, isEmpty);
      expect(cleaned.modsFolder, isEmpty);
    });
  });
}
