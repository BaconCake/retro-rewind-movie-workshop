import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/services/setup_autodetect.dart';

void main() {
  group('SetupAutoDetect.findToolsNear', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_setup_autodetect_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('finds both tools next to the executable', () async {
      final tx = File(p.join(tmp.path, 'texconv.exe'));
      final rp = File(p.join(tmp.path, 'repak.exe'));
      await tx.writeAsString('');
      await rp.writeAsString('');

      final r = SetupAutoDetect.findToolsNear(tmp.path);
      expect(r.texconv, tx.path);
      expect(r.repak, rp.path);
    });

    test('finds tools in a tools/ subfolder when exeDir is empty', () async {
      final sub = await Directory(p.join(tmp.path, 'tools')).create();
      final tx = File(p.join(sub.path, 'texconv.exe'));
      final rp = File(p.join(sub.path, 'repak.exe'));
      await tx.writeAsString('');
      await rp.writeAsString('');

      final r = SetupAutoDetect.findToolsNear(tmp.path);
      expect(r.texconv, tx.path);
      expect(r.repak, rp.path);
    });

    test('exeDir wins over tools/ subfolder', () async {
      final sub = await Directory(p.join(tmp.path, 'tools')).create();
      final txTop = File(p.join(tmp.path, 'texconv.exe'));
      final txSub = File(p.join(sub.path, 'texconv.exe'));
      await txTop.writeAsString('');
      await txSub.writeAsString('');

      final r = SetupAutoDetect.findToolsNear(tmp.path);
      expect(r.texconv, txTop.path,
          reason: 'closer-to-exe candidate must win when both exist');
    });

    test('returns null fields when nothing is found', () {
      final r = SetupAutoDetect.findToolsNear(tmp.path);
      expect(r.texconv, isNull);
      expect(r.repak, isNull);
    });
  });

  group('SetupAutoDetect.parseLibraryRoots', () {
    test('extracts every path from a real-shape libraryfolders.vdf', () {
      const vdf = '''
"libraryfolders"
{
\t"0"
\t{
\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
\t\t"label"\t\t""
\t\t"contentid"\t"123"
\t}
\t"1"
\t{
\t\t"path"\t\t"D:\\\\SteamLibrary"
\t\t"label"\t\t""
\t}
}
''';
      final roots = SetupAutoDetect.parseLibraryRoots(vdf);
      expect(roots, [
        r'C:\Program Files (x86)\Steam',
        r'D:\SteamLibrary',
      ]);
    });

    test('returns empty list when vdf has no path keys', () {
      const vdf = '"libraryfolders" { }';
      expect(SetupAutoDetect.parseLibraryRoots(vdf), isEmpty);
    });

    test('handles linux-style forward-slash paths', () {
      const vdf = '"path" "/home/user/.steam/steam"';
      expect(SetupAutoDetect.parseLibraryRoots(vdf),
          ['/home/user/.steam/steam']);
    });
  });

  group('SetupAutoDetect.deriveModsFolder', () {
    test('points to ~mods next to the pak', () {
      final pak = p.join('D:', 'SteamLibrary', 'steamapps', 'common',
          'RetroRewind', 'RetroRewind', 'Content', 'Paks',
          'RetroRewind-Windows.pak');
      final mods = SetupAutoDetect.deriveModsFolder(pak);
      expect(p.basename(mods), '~mods');
      expect(p.dirname(mods), p.dirname(pak));
    });
  });
}
