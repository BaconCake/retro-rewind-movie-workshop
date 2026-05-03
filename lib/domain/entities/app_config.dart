/// Configuration loaded from config.json. Mirrors the Python tool's schema
/// (RR_VHS_Tool.py:2262-2277) — same field names so users can switch tools
/// without re-entering paths.
class AppConfig {
  final String texconv;
  final String repak;
  final String baseGamePak;
  final String modsFolder;

  const AppConfig({
    required this.texconv,
    required this.repak,
    required this.baseGamePak,
    required this.modsFolder,
  });

  const AppConfig.empty()
      : texconv = '',
        repak = '',
        baseGamePak = '',
        modsFolder = '';

  AppConfig copyWith({
    String? texconv,
    String? repak,
    String? baseGamePak,
    String? modsFolder,
  }) {
    return AppConfig(
      texconv: texconv ?? this.texconv,
      repak: repak ?? this.repak,
      baseGamePak: baseGamePak ?? this.baseGamePak,
      modsFolder: modsFolder ?? this.modsFolder,
    );
  }

  bool get hasRepak => repak.isNotEmpty;
  bool get hasModsFolder => modsFolder.isNotEmpty;
}
