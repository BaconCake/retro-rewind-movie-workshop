import '../../core/constants/genres.dart';
import '../../domain/entities/texture.dart';
import '../../domain/repositories/texture_repository.dart';

/// Slice 1 implementation: always uses the sequential fallback path from
/// `build_texture_list()` (RR_VHS_Tool.py:1952-1976). Slice 2 will overlay
/// CLEAN_DT_SLOT_DATA when present.
class TextureRepositoryImpl implements TextureRepository {
  @override
  List<Texture> buildTextureList() {
    final out = <Texture>[];
    for (final g in kGenres) {
      final folder = 'T_Bkg_${g.code}';
      for (var i = 1; i <= g.bkgCount; i++) {
        final name = i < 100
            ? 'T_Bkg_${g.code}_${i.toString().padLeft(3, '0')}'
            : 'T_Bkg_${g.code}_$i';
        out.add(Texture(genre: g.name, folder: folder, name: name));
      }
    }
    return out;
  }
}
