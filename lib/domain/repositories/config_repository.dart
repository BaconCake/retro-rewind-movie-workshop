import '../entities/app_config.dart';

abstract class ConfigRepository {
  /// Load config.json from the working directory, returning an empty config
  /// if the file does not exist or any field is missing.
  Future<AppConfig> load();

  /// Persist config.json with 2-space indentation (matches Python).
  Future<void> save(AppConfig config);
}
