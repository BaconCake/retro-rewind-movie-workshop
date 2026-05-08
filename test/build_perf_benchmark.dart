// Manual benchmark runner — NOT part of the test suite.  Runs
// [PakBuilderImpl.build] against the user's actual data (real
// config.json + custom_slots.json + replacements.json + nr_custom_slots.json
// from the project root) and prints the phase-by-phase timings.
//
// Usage: `flutter test test/build_perf_benchmark.dart`
//
// Skips automatically when the project root config/JSONs are missing
// (so CI without the user's data goes green).  Always strips
// `mods_folder` so the live `~mods` folder is never touched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rr_movie_workshop/data/datasources/json_file_data_source.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';
import 'package:rr_movie_workshop/data/repositories/pak_builder_impl.dart';

void main() {
  test('benchmark: build with real user data', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final cwd = Directory.current.path;
    final cfgPath = p.join(cwd, 'config.json');
    if (!File(cfgPath).existsSync()) {
      markTestSkipped('config.json missing — run from project root');
      return;
    }
    final cfgJson = await JsonFileDataSource().readJson(cfgPath);
    if (cfgJson == null) {
      markTestSkipped('config.json unreadable');
      return;
    }
    final config =
        ConfigDto.fromJson(cfgJson).toEntity().copyWith(modsFolder: '');
    if (!File(config.repak).existsSync() ||
        !File(config.baseGamePak).existsSync() ||
        !File(config.texconv).existsSync()) {
      markTestSkipped('tools/base pak unavailable');
      return;
    }

    // Run the build in a temp dir, but copy the user's JSON state files
    // first so the build sees realistic input.  Replacement paths are
    // absolute — they work from any cwd.
    final temp = await Directory.systemTemp.createTemp('rr_perf_');
    Future<void> copyIfExists(String name) async {
      final src = File(p.join(cwd, name));
      if (await src.exists()) {
        await src.copy(p.join(temp.path, name));
      }
    }

    await Future.wait([
      copyIfExists('custom_slots.json'),
      copyIfExists('replacements.json'),
      copyIfExists('nr_custom_slots.json'),
      copyIfExists('config.json'),
    ]);

    Future<void> runBuild(String label) async {
      final builder = PakBuilderImpl(temp.path);
      final logs = <String>[];
      final sub = builder.logStream.listen(logs.add);
      final result = await builder.build(config);
      await pumpEventQueue();
      await sub.cancel();
      builder.dispose();
      // ignore: avoid_print
      print('\n=== $label ===\n${logs.join('\n')}\n');
      expect(result.success, isTrue,
          reason: '$label failed: ${result.errorCode} ${result.errorMessage}');
    }

    await runBuild('COLD CACHE BUILD');
    await runBuild('WARM CACHE BUILD');

    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 10)));
}
