import '../../domain/entities/app_config.dart';

/// JSON envelope for `config.json`. Python writes/reads exactly these four
/// keys (RR_VHS_Tool.py:2267); missing keys default to empty string so a
/// freshly-created file does not crash the loader.
class ConfigDto {
  final String texconv;
  final String repak;
  final String baseGamePak;
  final String modsFolder;

  const ConfigDto({
    required this.texconv,
    required this.repak,
    required this.baseGamePak,
    required this.modsFolder,
  });

  factory ConfigDto.fromJson(Map<String, dynamic> json) {
    return ConfigDto(
      texconv: (json['texconv'] as String?) ?? '',
      repak: (json['repak'] as String?) ?? '',
      baseGamePak: (json['base_game_pak'] as String?) ?? '',
      modsFolder: (json['mods_folder'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'texconv': texconv,
        'repak': repak,
        'base_game_pak': baseGamePak,
        'mods_folder': modsFolder,
      };

  AppConfig toEntity() => AppConfig(
        texconv: texconv,
        repak: repak,
        baseGamePak: baseGamePak,
        modsFolder: modsFolder,
      );

  factory ConfigDto.fromEntity(AppConfig c) => ConfigDto(
        texconv: c.texconv,
        repak: c.repak,
        baseGamePak: c.baseGamePak,
        modsFolder: c.modsFolder,
      );
}
