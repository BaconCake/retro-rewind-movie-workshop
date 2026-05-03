import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/dtos/config_dto.dart';

void main() {
  group('ConfigDto', () {
    test('parses the exact field names the Python tool writes', () {
      // Sample matches the schema in RR_VHS_Tool.py:2267 verbatim.
      final json = jsonDecode('''
{
  "texconv": "C:/tools/texconv.exe",
  "repak":   "C:/tools/repak.exe",
  "base_game_pak": "D:/Steam/RetroRewind-Windows.pak",
  "mods_folder":   "D:/Steam/~mods"
}
''') as Map<String, dynamic>;

      final dto = ConfigDto.fromJson(json);

      expect(dto.texconv, 'C:/tools/texconv.exe');
      expect(dto.repak, 'C:/tools/repak.exe');
      expect(dto.baseGamePak, 'D:/Steam/RetroRewind-Windows.pak');
      expect(dto.modsFolder, 'D:/Steam/~mods');
    });

    test('missing fields default to empty string (Python behavior)', () {
      final dto = ConfigDto.fromJson({});
      expect(dto.texconv, '');
      expect(dto.repak, '');
      expect(dto.baseGamePak, '');
      expect(dto.modsFolder, '');
    });

    test('round-trips through JSON without losing fields', () {
      const original = ConfigDto(
        texconv: 'a',
        repak: 'b',
        baseGamePak: 'c',
        modsFolder: 'd',
      );
      final round = ConfigDto.fromJson(original.toJson());
      expect(round.texconv, 'a');
      expect(round.repak, 'b');
      expect(round.baseGamePak, 'c');
      expect(round.modsFolder, 'd');
    });

    test('JSON keys match Python (snake_case for compound fields)', () {
      final json = const ConfigDto(
        texconv: '',
        repak: '',
        baseGamePak: '',
        modsFolder: '',
      ).toJson();
      expect(json.keys, containsAll(['texconv', 'repak', 'base_game_pak', 'mods_folder']));
    });
  });
}
