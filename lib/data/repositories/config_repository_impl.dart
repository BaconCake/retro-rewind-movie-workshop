import 'package:path/path.dart' as p;

import '../../domain/entities/app_config.dart';
import '../../domain/repositories/config_repository.dart';
import '../datasources/json_file_data_source.dart';
import '../dtos/config_dto.dart';

class ConfigRepositoryImpl implements ConfigRepository {
  final JsonFileDataSource _ds;
  final String _workingDir;

  ConfigRepositoryImpl(this._ds, this._workingDir);

  String get _configPath => p.join(_workingDir, 'config.json');

  @override
  Future<AppConfig> load() async {
    final json = await _ds.readJson(_configPath);
    if (json == null) return const AppConfig.empty();
    // Clear paths whose targets no longer exist on disk so a config copied
    // between machines (or surviving a game/tool reinstall) doesn't silently
    // ride invalid strings.  Pure port of Python's `load_config`
    // (RR_VHS_Tool.py:2715-2719).
    return ConfigDto.fromJson(json).toEntity().withClearedStalePaths();
  }

  @override
  Future<void> save(AppConfig config) async {
    final dto = ConfigDto.fromEntity(config);
    await _ds.writeJson(_configPath, dto.toJson());
  }
}
