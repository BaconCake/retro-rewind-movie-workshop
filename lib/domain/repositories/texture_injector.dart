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

  /// For an NR slot **without** a user image, write the
  /// `T_New_<code>_<NN:03d>.{uasset,uexp,ubulk}` trio into [workRoot] by
  /// cloning the `T_New_Hor_01` donor from the base pak.  Pure port of
  /// `ensure_nr_texture` + `prepare_nr_donor_in_cache`
  /// (RR_VHS_Tool.py:2311-2384, 2564-2593, 14756-14759).
  ///
  /// Without this, NR slots with no custom cover ship no 3-digit T_New
  /// asset at all and resolve to nothing in-game (the base pak only ships
  /// 2-digit T_New slots — `T_New_Dra_01..03`, never `T_New_Dra_001`).
  ///
  /// Idempotent: if all three files already exist (e.g. [inject] already
  /// produced them for a slot that does have a user image), this is a
  /// no-op and returns `false`.  Returns `true` when a clone was written.
  Future<bool> writeNrDonorClone({
    required AppConfig config,
    required String workRoot,
    required String genreCode,
    required int texNum,
  });
}
