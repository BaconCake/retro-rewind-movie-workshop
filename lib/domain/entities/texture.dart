/// One enumerated texture slot. Mirrors the dict shape returned by the Python
/// `build_texture_list()` (RR_VHS_Tool.py:1952-1976).
class Texture {
  final String genre;
  final String folder;
  final String name;
  final String type;

  const Texture({
    required this.genre,
    required this.folder,
    required this.name,
    this.type = 'Background',
  });
}
