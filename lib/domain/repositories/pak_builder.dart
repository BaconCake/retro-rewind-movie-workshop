import '../entities/app_config.dart';
import '../entities/build_result.dart';

/// One progress tick from a running build.  [current] always advances; the
/// fraction `current/total` is what the UI binds a progress bar to.
/// [label] describes the unit just completed (e.g. "Injected T_Bkg_Hor_001").
class BuildProgress {
  final int current;
  final int total;
  final String label;

  const BuildProgress({
    required this.current,
    required this.total,
    required this.label,
  });

  double get fraction => total == 0 ? 0 : (current / total).clamp(0.0, 1.0);
}

/// Builds and installs the mod pak. Slice 1 produces a passthrough pak — the
/// game accepts it but it doesn't change anything in-game yet. The log stream
/// emits human-readable lines (already prefixed with "[Build] ").
abstract class PakBuilder {
  Stream<String> get logStream;

  /// Per-unit-of-work events emitted as the build progresses through its
  /// phases.  Total is set at the start of [build]; current advances by 1
  /// per slot inject / DataTable write / per asset.
  Stream<BuildProgress> get progressStream;

  Future<BuildResult> build(AppConfig config);
}
