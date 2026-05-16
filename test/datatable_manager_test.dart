import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_builder.dart';
import 'package:rr_movie_workshop/data/datatable/datatable_manager.dart';
import 'package:rr_movie_workshop/data/datatable/slot_data.dart';
import 'package:rr_movie_workshop/data/services/pak_cache.dart';
import 'package:rr_movie_workshop/domain/entities/app_config.dart';

/// Test double for [DataTableBuilder]: succeeds for everything except the
/// DataTable names in [failOn], which throw a [DataTableBuildError].  Lets
/// us exercise [DataTableManager.buildAllLenient] without a real pak.
class _StubBuilder extends DataTableBuilder {
  final Set<String> failOn;
  final String failCode;
  _StubBuilder(super.pakCache, {
    this.failOn = const {},
    this.failCode = 'E005',
  });

  @override
  Future<DataTableBuildResult> build(
    AppConfig config,
    String dataTableName, {
    List<SlotData>? slotOverride,
    Map<String, String> titleOverrides = const {},
    Map<int, String> bkgTexPatches = const {},
  }) async {
    if (failOn.contains(dataTableName)) {
      throw DataTableBuildError(
          failCode, dataTableName, 'stubbed failure for $dataTableName');
    }
    return DataTableBuildResult(
      dataTableName: dataTableName,
      uassetBytes: Uint8List.fromList([1, 2, 3]),
      uexpBytes: Uint8List.fromList([4, 5, 6, 7]),
      slotCount: slotOverride?.length ?? 0,
    );
  }
}

class _ThrowingBuilder extends DataTableBuilder {
  _ThrowingBuilder(super.pakCache);

  @override
  Future<DataTableBuildResult> build(
    AppConfig config,
    String dataTableName, {
    List<SlotData>? slotOverride,
    Map<String, String> titleOverrides = const {},
    Map<int, String> bkgTexPatches = const {},
  }) async {
    throw StateError('unexpected non-build error in $dataTableName');
  }
}

void main() {
  group('DataTableManager.buildAllLenient (A5 — partial failure handling)', () {
    final cache = PakCache('/tmp/unused');  // never invoked by stubs
    const cfg = AppConfig.empty();
    const dramaOverride = <SlotData>[
      SlotData(
        bkgTex: 'T_Bkg_Dra_001',
        pnName: 'Drama_001',
        ls: 1,
        lsc: 4,
        sku: 12345,
        subTex: 'T_Sub_01',
      ),
    ];
    const horrorOverride = <SlotData>[
      SlotData(
        bkgTex: 'T_Bkg_Hor_001',
        pnName: 'Horror_001',
        ls: 1,
        lsc: 4,
        sku: 12346,
        subTex: 'T_Sub_02',
      ),
    ];

    test('reports both successes and failures from one pass', () async {
      final mgr = DataTableManager(_StubBuilder(cache, failOn: {'Drama'}));
      final outcome = await mgr.buildAllLenient(
        cfg,
        slotOverrides: {
          'Drama': dramaOverride,
          'Horror': horrorOverride,
        },
      );
      expect(outcome.built.keys, ['Horror']);
      expect(outcome.failed.keys, ['Drama']);
      expect(outcome.failed['Drama']!.code, 'E005');
      expect(outcome.allSuccess, isFalse);
    });

    test('all-success run reports empty failed map', () async {
      final mgr = DataTableManager(_StubBuilder(cache));
      final outcome = await mgr.buildAllLenient(
        cfg,
        slotOverrides: {'Drama': dramaOverride, 'Horror': horrorOverride},
      );
      expect(outcome.built.length, 2);
      expect(outcome.failed, isEmpty);
      expect(outcome.allSuccess, isTrue);
    });

    test('genres without overrides are skipped (CUSTOM_ONLY_MODE)', () async {
      // Only Drama is overridden — Horror, Action, etc. must not appear.
      final mgr = DataTableManager(_StubBuilder(cache));
      final outcome = await mgr.buildAllLenient(
        cfg,
        slotOverrides: {'Drama': dramaOverride},
      );
      expect(outcome.built.keys.toList(), ['Drama']);
      expect(outcome.failed, isEmpty);
    });

    test('unexpected throws are wrapped as E004 (Python except Exception)',
        () async {
      final mgr = DataTableManager(_ThrowingBuilder(cache));
      final outcome = await mgr.buildAllLenient(
        cfg,
        slotOverrides: {'Drama': dramaOverride},
      );
      expect(outcome.built, isEmpty);
      expect(outcome.failed.keys, ['Drama']);
      expect(outcome.failed['Drama']!.code, 'E004',
          reason: 'non-DataTableBuildError throws must wrap to E004');
    });

    test('E015 struct errors are preserved with their code', () async {
      final mgr = DataTableManager(
          _StubBuilder(cache, failOn: {'Drama'}, failCode: 'E015'));
      final outcome = await mgr.buildAllLenient(
        cfg,
        slotOverrides: {'Drama': dramaOverride},
      );
      expect(outcome.failed['Drama']!.code, 'E015');
    });

    test('log callback fires for each genre with start + outcome', () async {
      final logs = <String>[];
      final mgr = DataTableManager(_StubBuilder(cache, failOn: {'Drama'}));
      await mgr.buildAllLenient(
        cfg,
        slotOverrides: {'Drama': dramaOverride, 'Horror': horrorOverride},
        log: (dt, msg) => logs.add('$dt: $msg'),
      );
      expect(logs, contains('Drama: building...'));
      expect(logs.any((l) => l.startsWith('Drama: FAILED')), isTrue);
      expect(logs, contains('Horror: building...'));
      expect(logs.any((l) => l.startsWith('Horror: ok')), isTrue);
    });
  });
}
