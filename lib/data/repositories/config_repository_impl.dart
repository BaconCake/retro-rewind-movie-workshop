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
    return ConfigDto.fromJson(json).toEntity();
  }

  @override
  Future<void> save(AppConfig config) async {
    final dto = ConfigDto.fromEntity(config);
    await _ds.writeJson(_configPath, dto.toJson());
  }
}
