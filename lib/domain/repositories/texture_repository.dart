import '../entities/texture.dart';

abstract class TextureRepository {
  /// Returns the full ordered texture list for all genres. Slice 1 always
  /// uses the sequential fallback path (no replacements.json yet).
  List<Texture> buildTextureList();
}
