import '../entities/app_config.dart';
import '../entities/texture_replacement.dart';

/// Replaces a single base-game texture slot with a user-supplied image.
/// Slice 3a scope: existing slots only (no `clone_texture_3digit` for
/// out-of-base slot numbers — that's slice 3b).
abstract class TextureInjector {
  /// Inject [replacement] for [textureName] into [workRoot] (the directory
  /// whose contents become the new pak).
  ///
  /// - [textureName]: full slot id, e.g. `T_Bkg_Hor_001`.
  /// - [genreCode]: 3-letter genre code matching the texture's folder
  ///   (`Hor` → `T_Bkg_Hor/`).
  /// - [workRoot]: same directory PakBuilder uses as the pak's root
  ///   (`<workingDir>/build_work` in the current build flow).
  ///
  /// Throws on any unrecoverable failure (texconv missing, source image
  /// undecodable, base files absent, write failure).  Caller is expected
  /// to wrap in try/catch and accumulate per-texture errors.
  Future<void> inject({
    required AppConfig config,
    required String workRoot,
    required String textureName,
    required String genreCode,
    required TextureReplacement replacement,
  });
}
