import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/datasources/json_file_data_source.dart';
import '../../data/repositories/config_repository_impl.dart';
import '../../data/repositories/pak_builder_impl.dart';
import '../../data/repositories/texture_repository_impl.dart';
import '../../domain/entities/app_config.dart';
import '../../domain/entities/texture.dart';
import '../../domain/repositories/config_repository.dart';
import '../../domain/repositories/pak_builder.dart';
import '../../domain/repositories/texture_repository.dart';

/// The directory the app treats as its working dir. We prefer the current
/// working directory if it contains config.json — this is what `flutter run`
/// gives us (project root), and it's also what the user gets when they
/// launch a built .exe from its own folder. Otherwise we fall back to the
/// directory containing the executable, matching the Python tool.
final workingDirProvider = Provider<String>((ref) {
  final cwd = Directory.current.path;
  if (File(p.join(cwd, 'config.json')).existsSync()) return cwd;

  final exe = Platform.resolvedExecutable;
  if (exe.contains('flutter_tester') || exe.endsWith('dart.exe')) {
    return cwd;
  }
  return p.dirname(exe);
});

final jsonDataSourceProvider =
    Provider<JsonFileDataSource>((ref) => JsonFileDataSource());

final configRepositoryProvider = Provider<ConfigRepository>((ref) {
  return ConfigRepositoryImpl(
    ref.watch(jsonDataSourceProvider),
    ref.watch(workingDirProvider),
  );
});

final textureRepositoryProvider =
    Provider<TextureRepository>((ref) => TextureRepositoryImpl());

final pakBuilderProvider = Provider<PakBuilder>((ref) {
  final builder = PakBuilderImpl(ref.watch(workingDirProvider));
  ref.onDispose(builder.dispose);
  return builder;
});

final configFutureProvider = FutureProvider<AppConfig>((ref) {
  return ref.watch(configRepositoryProvider).load();
});

final texturesProvider = Provider<List<Texture>>((ref) {
  return ref.watch(textureRepositoryProvider).buildTextureList();
});

class BuildState {
  final bool isRunning;
  final List<String> log;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int? lastPakSizeBytes;
  final String? lastInstalledPath;

  const BuildState({
    this.isRunning = false,
    this.log = const [],
    this.lastErrorCode,
    this.lastErrorMessage,
    this.lastPakSizeBytes,
    this.lastInstalledPath,
  });

  BuildState copyWith({
    bool? isRunning,
    List<String>? log,
    String? lastErrorCode,
    String? lastErrorMessage,
    int? lastPakSizeBytes,
    String? lastInstalledPath,
  }) {
    return BuildState(
      isRunning: isRunning ?? this.isRunning,
      log: log ?? this.log,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      lastPakSizeBytes: lastPakSizeBytes ?? this.lastPakSizeBytes,
      lastInstalledPath: lastInstalledPath ?? this.lastInstalledPath,
    );
  }
}

class BuildController extends StateNotifier<BuildState> {
  final Ref _ref;

  BuildController(this._ref) : super(const BuildState()) {
    _ref.read(pakBuilderProvider).logStream.listen((line) {
      state = state.copyWith(log: [...state.log, line]);
    });
  }

  Future<void> ship() async {
    if (state.isRunning) return;
    state = const BuildState(isRunning: true, log: []);

    final config = await _ref.read(configRepositoryProvider).load();
    final result = await _ref.read(pakBuilderProvider).build(config);

    state = state.copyWith(
      isRunning: false,
      lastErrorCode: result.errorCode,
      lastErrorMessage: result.errorMessage,
      lastPakSizeBytes: result.pakSizeBytes,
      lastInstalledPath: result.installedPath,
    );
  }
}

final buildControllerProvider =
    StateNotifierProvider<BuildController, BuildState>((ref) {
  return BuildController(ref);
});
