import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/core/constants/uexp_template.dart';
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_parser.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/repositories/pak_builder_impl.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';
import 'package:rr_movie_workshop/domain/entities/new_release_slot.dart';

bool _bytesContainAscii(List<int> bytes, String needle) {
  final n = needle.codeUnits;
  if (n.isEmpty || n.length > bytes.length) return false;
  outer:
  for (var i = 0; i <= bytes.length - n.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (bytes[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// True when [a] and [b] are byte-identical outside the inline-mip regions
/// (the slots that get overwritten by composeArtifacts).  Used to detect
/// whether the injector pulled the empty T_Bkg template vs a real base-game
/// T_New uexp — both are 1702 bytes, but the non-mip header bytes differ.
bool _uexpHeadersEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  // Build a set of byte positions covered by inline mips.
  final mipBytes = <int>{};
  for (final entry in kUexpInlineMipMap) {
    final (_, off, sz) = entry;
    for (var i = 0; i < sz; i++) {
      mipBytes.add(off + i);
    }
  }
  for (var i = 0; i < a.length; i++) {
    if (mipBytes.contains(i)) continue;
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// End-to-end test for the New Release pipeline (slice 5d).
///
/// Drives the full [PakBuilderImpl.build] against the real base-game pak +
/// real repak.exe + real texconv.exe, then unpacks the resulting `.pak` and
/// verifies that every artifact slice 5 promised actually landed at the right
/// path with the right content.
///
/// Skips automatically when `config.json` (or any of the tools it points at)
/// is missing — so CI without the prod tools still goes green.
///
/// **Why this exists:** unit tests cover each builder in isolation but the
/// `_writeNrAssets` orchestration in `pak_builder_impl.dart` is only exercised
/// in-game.  This test catches "wrong path / missing file / wrong bytes"
/// mistakes before the user has to launch Mario Kart.
void main() {
  group('NR pak end-to-end (real repak + texconv + base pak)', () {
    late AppConfig config;
    late Directory tempDir;
    late bool fixturesAvailable;

    final slots = <NewReleaseSlot>[
      // 3-digit bkgTex naming as of v1.8.2 (slice 2a.3): the NR DT builder
      // rejects 12-char (2-digit) values now.  Slot numbering is still
      // 1..99 — only the FName encoding switched to 3 digits.
      const NewReleaseSlot(
        title: 'E2E Drama',
        genre: 'Drama',
        genreCode: 'Dra',
        genreByte: 0x02,
        bkgTex: 'T_New_Dra_001',
        sku: 50000,
        standeeShape: 'A',
        texNum: 1,
      ),
      const NewReleaseSlot(
        title: 'E2E Horror',
        genre: 'Horror',
        genreCode: 'Hor',
        genreByte: 0x05,
        bkgTex: 'T_New_Hor_002',
        sku: 51000,
        standeeShape: 'B',
        texNum: 2,
      ),
      const NewReleaseSlot(
        title: 'E2E SciFi',
        genre: 'Sci-Fi',
        genreCode: 'Sci',
        genreByte: 0x07,
        bkgTex: 'T_New_Sci_003',
        sku: 52000,
        standeeShape: 'C',
        texNum: 3,
      ),
    ];

    setUpAll(() async {
      // Required so PakBuilderImpl's `StandeeTemplates.load()` can read
      // bundled assets via rootBundle.
      TestWidgetsFlutterBinding.ensureInitialized();

      final cwd = Directory.current.path;
      final cfgPath = p.join(cwd, 'config.json');
      if (!File(cfgPath).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      final json = await JsonFileDataSource().readJson(cfgPath);
      if (json == null) {
        fixturesAvailable = false;
        return;
      }
      final loaded = ConfigDto.fromJson(json).toEntity();
      // Strip modsFolder so the build never touches the live ~mods folder.
      config = loaded.copyWith(modsFolder: '');
      if (!File(config.repak).existsSync() ||
          !File(config.baseGamePak).existsSync() ||
          !File(config.texconv).existsSync()) {
        fixturesAvailable = false;
        return;
      }
      fixturesAvailable = true;

      // Per-test isolated working dir, so we don't dirty the project dir.
      tempDir = await Directory.systemTemp.createTemp('rr_nr_e2e_');
      // Write the NR slot file PakBuilderImpl will read.
      await File(p.join(tempDir.path, 'nr_custom_slots.json')).writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert([for (final s in slots) s.toJson()]),
      );
    });

    tearDownAll(() async {
      if (!fixturesAvailable) return;
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Pak/cache files may briefly hold locks on Windows — don't fail
        // the suite over cleanup.
      }
    });

    test('build → unpack → all NR artifacts present at documented paths',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('config.json or tools unavailable');
        return;
      }

      final builder = PakBuilderImpl(tempDir.path);
      final logLines = <String>[];
      final logSub = builder.logStream.listen(logLines.add);

      final result = await builder.build(config);
      await logSub.cancel();
      builder.dispose();

      expect(
        result.success,
        isTrue,
        reason: 'PakBuilder.build failed: '
            'code=${result.errorCode} msg=${result.errorMessage}\n'
            'Logs:\n${logLines.join('\n')}',
      );
      expect(result.pakPath, isNotNull);
      expect(File(result.pakPath!).existsSync(), isTrue);

      // Unpack the freshly-built pak with repak so we can poke at every
      // file inside it.  `unpack` infers the format — no --version flag
      // (only `pack` takes one).
      final unpackDir = Directory(p.join(tempDir.path, 'unpacked'));
      if (await unpackDir.exists()) {
        await unpackDir.delete(recursive: true);
      }
      final unpackRes = await Process.run(
        config.repak,
        ['unpack', '--output', unpackDir.path, result.pakPath!],
      );
      expect(
        unpackRes.exitCode,
        0,
        reason: 'repak unpack failed: ${unpackRes.stderr}',
      );

      // Helper: assert a file exists, but on failure dump build log + the
      // full unpacked tree so a wrong path / missing file is obvious from
      // the test output without re-running.
      void expectFile(String path, String reason) {
        if (File(path).existsSync()) return;
        // ignore: avoid_print
        print('\n=== Missing: $path ===');
        // ignore: avoid_print
        print('\n--- Build log ---\n${logLines.join('\n')}');
        // ignore: avoid_print
        print('\n--- Unpacked pak contents (${unpackDir.path}) ---');
        if (unpackDir.existsSync()) {
          for (final f in unpackDir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
            // ignore: avoid_print
            print('  ${p.relative(f.path, from: unpackDir.path)}');
          }
        }
        fail(reason);
      }

      // 1) NR DataTable pair lands at the documented path.
      final dtBase = p.join(
        unpackDir.path,
        'RetroRewind',
        'Content',
        'VideoStore',
        'core',
        'blueprint',
        'data',
      );
      final dtUasset =
          File(p.join(dtBase, 'NewRelease_Details_-_Data.uasset'));
      final dtUexp = File(p.join(dtBase, 'NewRelease_Details_-_Data.uexp'));
      expectFile(dtUasset.path, 'NR DT uasset missing in built pak');
      expectFile(dtUexp.path, 'NR DT uexp missing in built pak');

      // 2) Per-slot trio lands at the documented paths (one MI, one
      //    thumbnail, one blueprint per slot).
      final assetRoot = p.join(unpackDir.path, 'RetroRewind', 'Content',
          'VideoStore', 'asset', 'prop');
      for (final s in slots) {
        // MI uses 3-digit naming (v1.8.2 — slice 2a.2): MI_New_<code>_<NN:03d>
        // even though bkg_tex still uses 2-digit until slice 2a.5 lands.
        final nn = s.texNum.toString().padLeft(3, '0');
        final mi = p.join(assetRoot, 'vhs', 'Background',
            'T_Bkg_${s.genreCode}', 'MI_New_${s.genreCode}_$nn');
        expectFile('$mi.uasset', 'MI uasset missing for ${s.bkgTex}');
        expectFile('$mi.uexp', 'MI uexp missing for ${s.bkgTex}');

        final thumb = p.join(assetRoot, 'Standees', 'Thumbnail',
            'T_Standees_Collection_${s.sku}');
        expectFile('$thumb.uasset', 'Thumbnail uasset missing for SKU ${s.sku}');
        expectFile('$thumb.uexp', 'Thumbnail uexp missing for SKU ${s.sku}');

        final bp = p.join(assetRoot, 'Standees', 'mesh',
            'Standees_Collection_${s.sku}');
        expectFile('$bp.uasset', 'Blueprint uasset missing for SKU ${s.sku}');
        expectFile('$bp.uexp', 'Blueprint uexp missing for SKU ${s.sku}');
      }

      // 3) Re-parse the NR DT and verify our titles all landed in the
      //    name table.  bkg_tex is an inline FString in the row body
      //    (not an FName), so we look for it as raw bytes in the uexp
      //    instead of in the name table.  Detailed offset-level checks
      //    live in newrelease_datatable_builder_test.dart — this layer
      //    only proves "the DT in the *built pak* contains our slots".
      final dtUexpBytes = await dtUexp.readAsBytes();
      final reparse = DataTableParser.parsePair(
        uassetBytes: await dtUasset.readAsBytes(),
        uexpBytes: dtUexpBytes,
        genreDataTableName: 'NewRelease_Details_-_Data',
      );
      final names =
          reparse.uasset.nameTable.entries.map((e) => e.value).toSet();
      for (final s in slots) {
        expect(names, contains(s.title),
            reason: 'NR title "${s.title}" not in name table');
        expect(_bytesContainAscii(dtUexpBytes, s.bkgTex), isTrue,
            reason: 'bkg_tex ${s.bkgTex} not present as inline FString in uexp');
      }
    },
        // Generous timeout: extracting the base pak + repak pack +
        // 3× texconv add up; on a cold cache this can take a minute.
        timeout: const Timeout(Duration(minutes: 3)));
  });

  /// Slice 3c — NR cover injection.  These tests prove the T_New_*
  /// build-side path: with a `replacements.json` entry pointing at a real
  /// PNG, the resulting pak must contain a real `T_New_<code>_NN.uasset/
  /// .uexp/.ubulk` triple at the same folder as the genre's T_Bkg
  /// textures.  The newCount==0 case (Romance) proves the cross-genre
  /// clone fallback (RR_VHS_Tool.py:5745-5793) lands real bytes too.
  group('NR cover injection (slice 3c)', () {
    late AppConfig config;
    late bool fixturesAvailable;

    Future<bool> loadConfig() async {
      final cwd = Directory.current.path;
      final cfgPath = p.join(cwd, 'config.json');
      if (!File(cfgPath).existsSync()) return false;
      final json = await JsonFileDataSource().readJson(cfgPath);
      if (json == null) return false;
      final loaded = ConfigDto.fromJson(json).toEntity();
      config = loaded.copyWith(modsFolder: '');
      return File(config.repak).existsSync() &&
          File(config.baseGamePak).existsSync() &&
          File(config.texconv).existsSync();
    }

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      fixturesAvailable = await loadConfig();
    });

    /// Set up a temp working dir with one NR slot + matching replacements
    /// entry pointing at a freshly-written PNG.  Returns the dir.
    Future<Directory> setupCoverFixture(NewReleaseSlot slot) async {
      final dir = await Directory.systemTemp.createTemp('rr_nr_cover_');
      // NR slot file.
      await File(p.join(dir.path, 'nr_custom_slots.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert([slot.toJson()]),
      );
      // 32×32 magenta source PNG — texconv handles the 1024×2048 upsizing
      // via the standard cover-fit path.
      final src = img.Image(width: 32, height: 32, numChannels: 3);
      img.fill(src, color: img.ColorRgb8(255, 0, 255));
      final pngPath = p.join(dir.path, 'cover.png');
      await File(pngPath).writeAsBytes(Uint8List.fromList(img.encodePng(src)));
      // replacements.json keyed by texture name (same key the Python tool uses).
      await File(p.join(dir.path, 'replacements.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          slot.bkgTex: {
            'path': pngPath,
            'offset_x': 0,
            'offset_y': 0,
            'zoom': 1.0,
          },
        }),
      );
      return dir;
    }

    Future<Directory> buildAndUnpack(Directory tempDir) async {
      final builder = PakBuilderImpl(tempDir.path);
      final result = await builder.build(config);
      builder.dispose();
      expect(result.success, isTrue,
          reason: 'build failed: ${result.errorCode} ${result.errorMessage}');
      final unpackDir = Directory(p.join(tempDir.path, 'unpacked'));
      final unpackRes = await Process.run(
        config.repak,
        ['unpack', '--output', unpackDir.path, result.pakPath!],
      );
      expect(unpackRes.exitCode, 0,
          reason: 'repak unpack failed: ${unpackRes.stderr}');
      return unpackDir;
    }

    test('injects real T_New cover for newCount>0 genre (Drama tex 1)',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      const slot = NewReleaseSlot(
        title: 'Cover Drama',
        genre: 'Drama',
        genreCode: 'Dra',
        genreByte: 0x02,
        bkgTex: 'T_New_Dra_001',
        sku: 50500,
        standeeShape: 'A',
        texNum: 1,
      );
      final tempDir = await setupCoverFixture(slot);
      try {
        final unpackDir = await buildAndUnpack(tempDir);
        final base = p.join(unpackDir.path, 'RetroRewind', 'Content',
            'VideoStore', 'asset', 'prop', 'vhs', 'Background', 'T_Bkg_Dra');
        final ua = File(p.join(base, '${slot.bkgTex}.uasset'));
        final ue = File(p.join(base, '${slot.bkgTex}.uexp'));
        final ub = File(p.join(base, '${slot.bkgTex}.ubulk'));
        expect(ua.existsSync(), isTrue, reason: 'T_New uasset not in pak');
        expect(ue.existsSync(), isTrue, reason: 'T_New uexp not in pak');
        expect(ub.existsSync(), isTrue, reason: 'T_New ubulk not in pak');

        // Sanity: ubulk is the canonical 5-mip size so the standee model
        // doesn't get pure-black close-ups.
        expect(ub.lengthSync(), kTNewUbulkSize,
            reason: 'ubulk size mismatch — close-up mips would be wrong');
        // Real T_New uexp is 1702 bytes — same size as kTBkgUexpTemplate by
        // coincidence (both are 5-mip-external uexps) — so we must compare
        // header bytes to prove we didn't fall back to the empty template
        // (Python's load-bearing distinction at RR_VHS_Tool.py:443).
        final ueBytes = await ue.readAsBytes();
        expect(_uexpHeadersEqual(ueBytes, kTBkgUexpTemplate), isFalse,
            reason: 'T_New uexp header equals T_Bkg empty template — '
                'injector fell back to the wrong source');
      } finally {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cross-genre clones T_New cover for newCount==0 genre (Romance)',
        () async {
      if (!fixturesAvailable) {
        markTestSkipped('fixtures unavailable');
        return;
      }
      // Romance has newCount=0 — the only path to a real T_New_Rom file is
      // the cross-genre clone of T_New_Hor_01 (RR_VHS_Tool.py:5745-5793).
      const slot = NewReleaseSlot(
        title: 'Cover Romance',
        genre: 'Romance',
        genreCode: 'Rom',
        genreByte: 0x09,
        bkgTex: 'T_New_Rom_001',
        sku: 50600,
        standeeShape: 'A',
        texNum: 1,
      );
      final tempDir = await setupCoverFixture(slot);
      try {
        final unpackDir = await buildAndUnpack(tempDir);
        final base = p.join(unpackDir.path, 'RetroRewind', 'Content',
            'VideoStore', 'asset', 'prop', 'vhs', 'Background', 'T_Bkg_Rom');
        final ua = File(p.join(base, '${slot.bkgTex}.uasset'));
        final ue = File(p.join(base, '${slot.bkgTex}.uexp'));
        final ub = File(p.join(base, '${slot.bkgTex}.ubulk'));
        expect(ua.existsSync(), isTrue,
            reason: 'cross-genre T_New_Rom uasset not in pak');
        expect(ue.existsSync(), isTrue,
            reason: 'cross-genre T_New_Rom uexp not in pak');
        expect(ub.existsSync(), isTrue,
            reason: 'cross-genre T_New_Rom ubulk not in pak');
        // The cloned uasset should reference T_Bkg_Rom (target genre)
        // rather than T_Bkg_Hor — that's the whole point of the patch.
        final uaBytes = await ua.readAsBytes();
        final hasRom = _bytesContainAscii(uaBytes, 'T_Bkg_Rom');
        final hasHor = _bytesContainAscii(uaBytes, 'T_Bkg_Hor');
        expect(hasRom, isTrue,
            reason: 'cloned uasset missing target T_Bkg_Rom reference');
        expect(hasHor, isFalse,
            reason: 'cloned uasset still carries source T_Bkg_Hor reference');
      } finally {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
