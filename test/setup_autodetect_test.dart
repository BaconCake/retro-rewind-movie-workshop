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

  group('SetupAutoDetect.resolveGameFolderPick (H3)', () {
    late Directory tmp;
    late String pakPath;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_resolve_game_');
      // Lay out the standard install structure: <root>/RetroRewind/Content/Paks/<pak>
      final paksDir = await Directory(
              p.join(tmp.path, 'RetroRewind', 'Content', 'Paks'))
          .create(recursive: true);
      final pak = File(p.join(paksDir.path, 'RetroRewind-Windows.pak'));
      await pak.writeAsString('');
      pakPath = pak.path;
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('picks the pak file directly', () {
      final r = SetupAutoDetect.resolveGameFolderPick(pakPath);
      expect(r.baseGamePak, pakPath);
      expect(p.basename(r.modsFolder!), '~mods');
      expect(p.dirname(r.modsFolder!), p.dirname(pakPath));
    });

    test('picks the Paks directory (one level above the pak)', () {
      final paksDir = p.dirname(pakPath);
      final r = SetupAutoDetect.resolveGameFolderPick(paksDir);
      expect(r.baseGamePak, pakPath);
      expect(r.modsFolder, p.join(paksDir, '~mods'));
    });

    test('picks the inner RetroRewind directory', () {
      final inner = p.join(tmp.path, 'RetroRewind'); // .../RetroRewind
      final r = SetupAutoDetect.resolveGameFolderPick(inner);
      expect(r.baseGamePak, pakPath);
    });

    test('picks the outer game-root directory', () {
      final r = SetupAutoDetect.resolveGameFolderPick(tmp.path);
      expect(r.baseGamePak, pakPath);
      expect(r.modsFolder, p.join(p.dirname(pakPath), '~mods'));
    });

    test('returns null when picked file is not the pak', () async {
      final wrong = File(p.join(tmp.path, 'something.txt'));
      await wrong.writeAsString('');
      final r = SetupAutoDetect.resolveGameFolderPick(wrong.path);
      expect(r.baseGamePak, isNull);
      expect(r.modsFolder, isNull);
    });

    test('returns null when picked dir contains no pak', () async {
      final empty = await Directory(p.join(tmp.path, 'empty')).create();
      final r = SetupAutoDetect.resolveGameFolderPick(empty.path);
      expect(r.baseGamePak, isNull);
      expect(r.modsFolder, isNull);
    });

    test('returns null for non-existent path', () {
      final r = SetupAutoDetect.resolveGameFolderPick(
          p.join(tmp.path, 'does-not-exist'));
      expect(r.baseGamePak, isNull);
      expect(r.modsFolder, isNull);
    });

    test('returns null for empty input', () {
      final r = SetupAutoDetect.resolveGameFolderPick('');
      expect(r.baseGamePak, isNull);
      expect(r.modsFolder, isNull);
    });
  });

  group('SetupAutoDetect Steam-scan H4', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_steam_h4_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// Build a fake Steam install at `<tmp>/Steam` with a config/ VDF
    /// listing a sibling library, plus its own `steamapps/`.
    Future<String> buildFakeSteamInstall({
      required List<String> libraryPaths,
      bool vdfInConfig = true,
      bool vdfInSteamApps = false,
    }) async {
      final steam = p.join(tmp.path, 'Steam');
      await Directory(p.join(steam, 'steamapps')).create(recursive: true);
      final vdfBody = StringBuffer('"libraryfolders"\n{\n');
      for (var i = 0; i < libraryPaths.length; i++) {
        // VDF escapes single backslashes as `\\`.
        final escaped = libraryPaths[i].replaceAll(r'\', r'\\');
        vdfBody.writeln('  "$i"\n  {\n    "path"  "$escaped"\n  }');
      }
      vdfBody.writeln('}');
      if (vdfInConfig) {
        await Directory(p.join(steam, 'config')).create(recursive: true);
        await File(p.join(steam, 'config', 'libraryfolders.vdf'))
            .writeAsString(vdfBody.toString());
      }
      if (vdfInSteamApps) {
        await File(p.join(steam, 'steamapps', 'libraryfolders.vdf'))
            .writeAsString(vdfBody.toString());
      }
      return steam;
    }

    test('readSteamVdfs unions config/ and steamapps/ VDFs', () async {
      final steam = await buildFakeSteamInstall(
        libraryPaths: ['/lib/a'],
        vdfInConfig: true,
        vdfInSteamApps: false,
      );
      // Overwrite steamapps/ VDF with a different library.
      final spVdf = File(p.join(steam, 'steamapps', 'libraryfolders.vdf'));
      await spVdf.writeAsString(
          '"libraryfolders" { "0" { "path" "/lib/b" } }');

      final libs = SetupAutoDetect.readSteamVdfs(steam);
      expect(libs.toSet(), {'/lib/a', '/lib/b'},
          reason: 'must union both VDF locations');
    });

    test('readSteamVdfs returns empty when no VDFs exist', () {
      final libs = SetupAutoDetect.readSteamVdfs(p.join(tmp.path, 'nope'));
      expect(libs, isEmpty);
    });

    test('findSteamLibrariesFromCandidates includes a root with steamapps/',
        () async {
      final steam = await buildFakeSteamInstall(libraryPaths: const []);
      final libs =
          SetupAutoDetect.findSteamLibrariesFromCandidates([steam]);
      expect(libs, contains(steam),
          reason: 'a path with steamapps/ is itself a library');
    });

    test('findSteamLibrariesFromCandidates skips paths without steamapps/',
        () async {
      final bare = await Directory(p.join(tmp.path, 'NotSteam')).create();
      final libs =
          SetupAutoDetect.findSteamLibrariesFromCandidates([bare.path]);
      expect(libs, isEmpty);
    });

    test('findSteamLibrariesFromCandidates unions install + VDF libraries',
        () async {
      final lib2 = await Directory(p.join(tmp.path, 'Lib2', 'steamapps'))
          .create(recursive: true);
      final lib2Root = p.dirname(lib2.path);
      final steam = await buildFakeSteamInstall(libraryPaths: [lib2Root]);
      final libs =
          SetupAutoDetect.findSteamLibrariesFromCandidates([steam]);
      expect(libs.toSet(), {steam, lib2Root});
    });

    test('findSteamLibrariesFromCandidates dedupes across overlapping inputs',
        () async {
      final steam = await buildFakeSteamInstall(libraryPaths: const []);
      final libs = SetupAutoDetect
          .findSteamLibrariesFromCandidates([steam, steam, steam]);
      expect(libs, [steam]);
    });
  });

  group('SetupAutoDetect.ensureModsFolder (H2)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('rr_ensure_mods_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('creates a missing directory and reports wasCreated', () {
      final target = p.join(tmp.path, '~mods');
      expect(Directory(target).existsSync(), isFalse);

      final r = SetupAutoDetect.ensureModsFolder(target);
      expect(r.wasCreated, isTrue);
      expect(r.existed, isFalse);
      expect(r.isOk, isTrue);
      expect(Directory(target).existsSync(), isTrue);
    });

    test('idempotent when the directory already exists', () async {
      final target = p.join(tmp.path, '~mods');
      await Directory(target).create();

      final r = SetupAutoDetect.ensureModsFolder(target);
      expect(r.existed, isTrue);
      expect(r.wasCreated, isFalse);
      expect(r.isOk, isTrue);
    });

    test('recursive create — parent directories are made as needed', () {
      final target =
          p.join(tmp.path, 'Steam', 'common', 'RetroRewind', 'Content',
              'Paks', '~mods');
      final r = SetupAutoDetect.ensureModsFolder(target);
      expect(r.wasCreated, isTrue);
      expect(Directory(target).existsSync(), isTrue);
    });

    test('empty path reports failed without touching disk', () {
      final r = SetupAutoDetect.ensureModsFolder('');
      expect(r.isOk, isFalse);
      expect(r.error, isNotNull);
    });
  });
}
