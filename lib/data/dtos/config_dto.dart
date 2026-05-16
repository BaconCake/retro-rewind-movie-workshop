import '../../domain/entities/app_config.dart';

/// JSON envelope for `config.json`. Python writes/reads exactly these keys
/// (RR_VHS_Tool.py:2267, 6878-6885); missing keys default to empty / false
/// so a freshly-created file does not crash the loader.
class ConfigDto {
  final String texconv;
  final String repak;
  final String baseGamePak;
  final String modsFolder;
  final bool devMode;

  const ConfigDto({
    required this.texconv,
    required this.repak,
    required this.baseGamePak,
    required this.modsFolder,
    this.devMode = false,
  });

  factory ConfigDto.fromJson(Map<String, dynamic> json) {
    return ConfigDto(
      texconv: (json['texconv'] as String?) ?? '',
      repak: (json['repak'] as String?) ?? '',
      baseGamePak: (json['base_game_pak'] as String?) ?? '',
      modsFolder: (json['mods_folder'] as String?) ?? '',
      devMode: (json['dev_mode'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'texconv': texconv,
        'repak': repak,
        'base_game_pak': baseGamePak,
        'mods_folder': modsFolder,
        'dev_mode': devMode,
      };

  AppConfig toEntity() => AppConfig(
        texconv: texconv,
        repak: repak,
        baseGamePak: baseGamePak,
        modsFolder: modsFolder,
        devMode: devMode,
      );

  factory ConfigDto.fromEntity(AppConfig c) => ConfigDto(
        texconv: c.texconv,
        repak: c.repak,
        baseGamePak: c.baseGamePak,
        modsFolder: c.modsFolder,
        devMode: c.devMode,
      );
}
