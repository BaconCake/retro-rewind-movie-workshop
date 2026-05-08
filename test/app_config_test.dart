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
}
