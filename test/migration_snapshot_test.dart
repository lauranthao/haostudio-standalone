// 路 A 迁移快照测试 (Swift 2.0 §5.3, Flutter 1.1.6+32).
//
// 覆盖:快照键与 box 键逐一对照无遗漏、每种值类型写出后再读回
// 类型一致、坏值容错不崩、envelope 字段齐全、原子写 (无残留
// .tmp)、覆盖写替换旧键、失败返回 false 不抛错、启动入口
// writeAfterStartup 走通真实 HiveStore + Documents 路径。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/logging/app_log.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/storage/local_paths.dart';
import 'package:standalone/core/storage/migration_snapshot.dart';

void main() {
  group('MigrationSnapshot', () {
    late Directory hiveDir;
    late Directory docsDir;
    late Box<dynamic> box;

    setUp(() async {
      AppLog.resetForTest();
      LocalPaths.resetForTest();
      hiveDir = await Directory.systemTemp.createTemp('hao-snap-hive-');
      docsDir = await Directory.systemTemp.createTemp('hao-snap-docs-');
      Hive.init(hiveDir.path);
      box = await Hive.openBox<dynamic>('app_settings');
    });

    tearDown(() async {
      try {
        await box.close();
      } catch (_) {}
      try {
        await Hive.close();
      } catch (_) {}
      try {
        await hiveDir.delete(recursive: true);
      } catch (_) {}
      try {
        await docsDir.delete(recursive: true);
      } catch (_) {}
      AppLog.resetForTest();
      LocalPaths.resetForTest();
    });

    Future<Map<String, dynamic>> readSnapshot() async {
      final file = File('${docsDir.path}/${MigrationSnapshot.fileName}');
      expect(await file.exists(), isTrue);
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    }

    test('envelope 字段齐全', () {
      final envelope = MigrationSnapshot.buildEnvelope(
        {'a': 'x'},
        appVersion: '1.1.6',
        appBuild: 32,
        now: DateTime.utc(2026, 11, 23, 7, 0, 0),
      );
      expect(envelope['schema'], MigrationSnapshot.schemaVersion);
      expect(envelope['schema'], 1);
      expect(envelope['app'], 'HAo Studio');
      expect(envelope['appVersion'], '1.1.6');
      // 读侧容忍规则:schema 必须为 1;appVersion 须为 `1.` 开头;
      // data 为空或不是字典则整个快照视为无效。
      expect((envelope['appVersion'] as String).startsWith('1.'), isTrue);
      expect(envelope['data'], isA<Map<String, dynamic>>());
      expect(envelope['appBuild'], 32);
      expect(DateTime.tryParse(envelope['exportedAt'] as String),
          isNotNull);
      expect(envelope['entries'], 1);
      expect(envelope['data'], {'a': 'x'});
      expect(envelope['types'], {'a': 'string'});
    });

    test('快照键与 box 键逐一对照,无遗漏无多余', () async {
      await box.put('videoPlayerKey', 'mpv');
      await box.put('preferResolution', '原画');
      await box.put('hao_lists', '[{"id":"1"}]');
      await box.put('haoVodProg:cms:123', 456);
      await box.put('hao_daily_2026-11-23', '{"pick":"x"}');
      await box.put('hao_eq_band_gains', <double>[0.0, 1.5, -2.0]);
      await box.put('hao_tabbar_accent_presets', <int>[0xFF000000]);
      await box.put('musicSpeed', 1.25);
      await box.put('autoResumeLastPlayback', true);
      await box.put('liveHistoryLimit', 50);

      final ok = await MigrationSnapshot.writeSnapshot(
        box: box,
        documentsDir: docsDir,
        appVersion: '1.1.6',
        appBuild: 32,
      );
      expect(ok, isTrue);

      final snapshot = await readSnapshot();
      expect(snapshot['entries'], 10);
      final data = snapshot['data'] as Map<String, dynamic>;
      final types = snapshot['types'] as Map<String, dynamic>;
      expect(data.keys.toSet(), box.keys.map((k) => k.toString()).toSet());
      expect(types.keys.toSet(), box.keys.map((k) => k.toString()).toSet());
      // 动态前缀键也在内,不是只导出 HiveKeys 常量表。
      expect(data.containsKey('haoVodProg:cms:123'), isTrue);
      expect(data.containsKey('hao_daily_2026-11-23'), isTrue);
      // 原子写:无残留临时文件。
      expect(
        File('${docsDir.path}/${MigrationSnapshot.fileName}.tmp')
            .existsSync(),
        isFalse,
      );
    });

    test('每种值类型写出后再读回类型一致', () async {
      await box.put('s', 'hello');
      await box.put('json', '{"a":1}');
      await box.put('jsonArr', '[{"id":"1"}]');
      await box.put('notJson', '{oops');
      await box.put('numStr', '123');
      await box.put('i', 42);
      await box.put('d', 3.5);
      await box.put('b', true);
      await box.put('ints', <int>[1, 2, 3]);
      await box.put('doubles', <double>[0.0, 1.5]);
      await box.put('mixedNums', <Object>[1, 2.5]);
      await box.put('strings', <String>['a', 'b']);
      await box.put('bools', <bool>[true, false]);
      await box.put('map', <String, dynamic>{'k': 'v', 'n': 1});
      await box.put('emptyList', <int>[]);

      expect(
        await MigrationSnapshot.writeSnapshot(
          box: box,
          documentsDir: docsDir,
          appVersion: '1.1.6',
          appBuild: 32,
        ),
        isTrue,
      );
      final snapshot = await readSnapshot();
      final data = snapshot['data'] as Map<String, dynamic>;
      final types = snapshot['types'] as Map<String, dynamic>;

      // 读侧契约:types 只许用 7 个标签。
      expect(
        types.values.every(
          (t) => MigrationSnapshot.allowedTypes.contains(t),
        ),
        isTrue,
      );

      expect(data['s'], 'hello');
      expect(data['s'], isA<String>());
      // json 标签:值保持原串,读侧先解析再落盘。
      expect(data['json'], '{"a":1}');
      expect(jsonDecode(data['json'] as String), {'a': 1});
      expect(data['jsonArr'], '[{"id":"1"}]');
      expect(jsonDecode(data['jsonArr'] as String), [
        {'id': '1'},
      ]);
      // 标量串与坏 JSON 串不是 json。
      expect(data['notJson'], '{oops');
      expect(data['numStr'], '123');
      expect(data['i'], 42);
      expect(data['i'], isA<int>());
      expect(data['d'], 3.5);
      expect(data['d'], isA<double>());
      expect(data['b'], isTrue);
      expect(data['ints'], [1, 2, 3]);
      expect(data['doubles'], [0.0, 1.5]);
      expect(data['doubles'], isA<List>());
      expect(data['mixedNums'], [1, 2.5]);
      // 非数值 List 与 Map:编成 JSON 字符串,读侧解析后原样落盘。
      expect(data['strings'], '["a","b"]');
      expect(jsonDecode(data['strings'] as String), ['a', 'b']);
      expect(data['bools'], '[true,false]');
      expect(data['map'], '{"k":"v","n":1}');
      expect(jsonDecode(data['map'] as String), {'k': 'v', 'n': 1});
      expect(data['emptyList'], <Object>[]);

      expect(types['s'], 'string');
      expect(types['json'], 'json');
      expect(types['jsonArr'], 'json');
      expect(types['notJson'], 'string');
      expect(types['numStr'], 'string');
      expect(types['i'], 'int');
      expect(types['d'], 'double');
      expect(types['b'], 'bool');
      expect(types['ints'], 'intList');
      // 探针 R1: List<double> (Hive typeId 7,如 hao_eq_band_gains)
      // 单列 'doubleList';int/double 混杂的列也归 'doubleList'
      // (读侧按 [Double] 解,整数位 widen)。
      expect(types['doubles'], 'doubleList');
      expect(types['mixedNums'], 'doubleList');
      expect(types['strings'], 'json');
      expect(types['bools'], 'json');
      expect(types['map'], 'json');
      expect(types['emptyList'], 'intList');
    });

    test('坏值容错不崩,其它键照常写出', () async {
      await box.put('good', 'keep-me');
      await box.put('nan', double.nan);
      await box.put('inf', double.infinity);
      await box.put('bytes', Uint8List.fromList([1, 2, 3]));
      await box.put('when', DateTime.utc(2026, 11, 23, 7, 0, 0));
      // 探针 R2:普通 DateTime (含 DateTime.utc) 走 typeId 18,
      // 本地 DateTime 同样解码为 DateTime;两者都以 UTC ISO 存。
      final localWhen = DateTime(2026, 11, 23, 15, 0, 0);
      await box.put('localWhen', localWhen);
      await box.put('badList', <Object>[1, double.nan]);
      await box.put('badMap', <Object, Object>{1: 'int-key'});

      expect(
        await MigrationSnapshot.writeSnapshot(
          box: box,
          documentsDir: docsDir,
          appVersion: '1.1.6',
          appBuild: 32,
        ),
        isTrue,
      );
      final snapshot = await readSnapshot();
      final data = snapshot['data'] as Map<String, dynamic>;
      final types = snapshot['types'] as Map<String, dynamic>;

      expect(data['good'], 'keep-me');
      // 非有限 double 与含 NaN 的集合:值置 null,标签记 'string'
      // (契约无坏值标签;读侧取不到 String 会安全跳过该键,
      // 键本身仍在 data 里,探针键集对照不受影响)。
      expect(data['nan'], isNull);
      expect(types['nan'], 'string');
      expect(data['inf'], isNull);
      expect(types['inf'], 'string');
      expect(data['badList'], isNull);
      expect(types['badList'], 'string');
      expect(data['badMap'], isNull);
      expect(types['badMap'], 'string');
      // 基线外的可保值:bytes → base64 文本,datetime → ISO 8601
      // 文本,标签都是 'string'。
      expect(data['bytes'], base64Encode([1, 2, 3]));
      expect(types['bytes'], 'string');
      expect(data['when'], '2026-11-23T07:00:00.000Z');
      expect(types['when'], 'string');
      expect(data['localWhen'], localWhen.toUtc().toIso8601String());
      expect(types['localWhen'], 'string');
      expect(snapshot['entries'], 8);
    });

    test('空 box 也能写出合法快照', () async {
      expect(
        await MigrationSnapshot.writeSnapshot(
          box: box,
          documentsDir: docsDir,
          appVersion: '1.1.6',
          appBuild: 32,
        ),
        isTrue,
      );
      final snapshot = await readSnapshot();
      expect(snapshot['entries'], 0);
      expect(snapshot['data'], isEmpty);
      expect(snapshot['types'], isEmpty);
    });

    test('覆盖写:删掉的键消失,改过的值更新', () async {
      await box.put('keep', 'v1');
      await box.put('gone', 'x');
      expect(
        await MigrationSnapshot.writeSnapshot(
          box: box,
          documentsDir: docsDir,
          appVersion: '1.1.6',
          appBuild: 32,
        ),
        isTrue,
      );
      await box.put('keep', 'v2');
      await box.delete('gone');
      await box.put('new', 7);
      expect(
        await MigrationSnapshot.writeSnapshot(
          box: box,
          documentsDir: docsDir,
          appVersion: '1.1.6',
          appBuild: 32,
        ),
        isTrue,
      );
      final snapshot = await readSnapshot();
      final data = snapshot['data'] as Map<String, dynamic>;
      expect(data, {'keep': 'v2', 'new': 7});
      expect(snapshot['entries'], 2);
    });

    test('写盘失败返回 false 不抛错,不留半份快照', () async {
      await box.put('k', 'v');
      // documentsDir 指向一个文件 (不是目录):写临时文件必失败。
      final notADir = File('${docsDir.path}/not-a-dir');
      await notADir.writeAsString('x');
      final ok = await MigrationSnapshot.writeSnapshot(
        box: box,
        documentsDir: Directory(notADir.path),
        appVersion: '1.1.6',
        appBuild: 32,
      );
      expect(ok, isFalse);
      // 失败不产生快照文件,也不留临时文件。
      expect(File('${docsDir.path}/${MigrationSnapshot.fileName}')
          .existsSync(), isFalse);
    });

    test('writeAfterStartup 走通真实 HiveStore + Documents 路径',
        () async {
      // 用真实 HiveStore.init (本文件其它测试用的是裸 Hive box)。
      await HiveStore.init(path: hiveDir.path);
      await HiveStore.put('videoPlayerKey', 'mpv');
      await HiveStore.put('musicSpeed', 1.25);
      LocalPaths.setDocumentsPathForTest(docsDir.path);

      await MigrationSnapshot.writeAfterStartup();

      final snapshot = await readSnapshot();
      expect(snapshot['schema'], MigrationSnapshot.schemaVersion);
      expect(snapshot['appVersion'], kAppVersion);
      expect(snapshot['appBuild'], kAppBuild);
      final data = snapshot['data'] as Map<String, dynamic>;
      expect(data['videoPlayerKey'], 'mpv');
      expect(data['musicSpeed'], 1.25);
    });
  });
}
