import '../entities/app_config.dart';
import '../entities/build_result.dart';

/// Builds and installs the mod pak. Slice 1 produces a passthrough pak — the
/// game accepts it but it doesn't change anything in-game yet. The log stream
/// emits human-readable lines (already prefixed with "[Build] ").
abstract class PakBuilder {
  Stream<String> get logStream;

  Future<BuildResult> build(AppConfig config);
}
