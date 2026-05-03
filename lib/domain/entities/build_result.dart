/// Result of a slice 1 build. The build emits log lines as it runs (consumed
/// via a stream) and finishes with one of these values.
class BuildResult {
  final bool success;
  final String? errorCode;
  final String? errorMessage;
  final String? pakPath;
  final String? installedPath;
  final int pakSizeBytes;

  const BuildResult.ok({
    required this.pakPath,
    required this.installedPath,
    required this.pakSizeBytes,
  })  : success = true,
        errorCode = null,
        errorMessage = null;

  const BuildResult.failure({
    required String code,
    required String message,
  })  : success = false,
        errorCode = code,
        errorMessage = message,
        pakPath = null,
        installedPath = null,
        pakSizeBytes = 0;
}
