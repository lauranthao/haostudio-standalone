// LX script files + deletable bundled scripts tests.
//
// - LxScriptFileStore: seed copies the asset on first launch, never
//   overwrites an existing copy, delete removes the file.
// - LxScriptSourcesStore deleted set: mark/unmark round-trips through
//   a throwaway Hive box and survives re-reads.
// - LxScriptEngine.removeScript: bundled delete removes the file copy
//   AND records the id, so a later ensureInitialized never loads it
//   again; custom delete removes the Hive record and does not touch
//   the deleted set.
// - ensureInitialized skips deleted bundled scripts (the other five
//   record failed infos on Linux because the JS runtime factory
//   throws there — the skip itself is what this asserts).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/lx_script_files.dart';
import 'package:standalone/services/music/lx_script_store.dart';

const String _dummyCode = '// @name Dummy\n// @version 1.0.0\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Box<dynamic> box;
  late Directory tempDir;

  setUp(() async {
    Hive.init('test/.hive-lx-files-test');
    box = await Hive.openBox<dynamic>('lx_files_test');
    await box.clear();
    HiveStore.setTestBox(box);
    tempDir = await Directory.systemTemp.createTemp('lx_files_test_');
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('lx_files_test');
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  LxScriptFileStore fileStore() =>
      LxScriptFileStore(dirResolver: () async => tempDir);

  group('LxScriptFileStore', () {
    test('seed copies the asset, read returns it', () async {
      final store = fileStore();
      await store.seedIfMissing(
        id: 'suyin',
        assetPath: 'assets/lx_scripts/suyin.js',
        assetLoader: (_) async => _dummyCode,
      );
      expect(await store.read('suyin'), _dummyCode);
      expect(
        await File('${tempDir.path}/suyin.js').exists(),
        isTrue,
      );
    });

    test('seed never overwrites an existing copy', () async {
      final store = fileStore();
      final file = File('${tempDir.path}/suyin.js');
      await file.writeAsString('user-edited');
      await store.seedIfMissing(
        id: 'suyin',
        assetPath: 'assets/lx_scripts/suyin.js',
        assetLoader: (_) async => _dummyCode,
      );
      expect(await store.read('suyin'), 'user-edited');
    });

    test('delete removes the file, read returns null after', () async {
      final store = fileStore();
      await store.seedIfMissing(
        id: 'suyin',
        assetPath: 'assets/lx_scripts/suyin.js',
        assetLoader: (_) async => _dummyCode,
      );
      await store.delete('suyin');
      expect(await store.read('suyin'), isNull);
      expect(await File('${tempDir.path}/suyin.js').exists(), isFalse);
    });

    test('delete of a missing file does not throw', () async {
      await fileStore().delete('nope');
      expect(await fileStore().read('nope'), isNull);
    });
  });

  group('LxScriptSourcesStore deleted bundled set', () {
    test('defaults to empty', () {
      expect(LxScriptSourcesStore.deletedBundledIds(box: box), isEmpty);
      expect(
        LxScriptSourcesStore.isBundledDeleted('suyin', box: box),
        isFalse,
      );
    });

    test('mark persists and unmark removes', () async {
      await LxScriptSourcesStore.markBundledDeleted('suyin', box: box);
      expect(
        LxScriptSourcesStore.isBundledDeleted('suyin', box: box),
        isTrue,
      );
      // Re-read through the global box (the engine's path).
      expect(LxScriptSourcesStore.isBundledDeleted('suyin'), isTrue);
      await LxScriptSourcesStore.markBundledDeleted('fish', box: box);
      expect(
        LxScriptSourcesStore.deletedBundledIds(box: box).toSet(),
        {'suyin', 'fish'},
      );
      await LxScriptSourcesStore.unmarkBundledDeleted('suyin', box: box);
      expect(
        LxScriptSourcesStore.deletedBundledIds(box: box),
        ['fish'],
      );
    });

    test('corrupt stored value falls back to empty', () async {
      await box.put(HiveKeys.lxDeletedBundledScripts, 'not json{');
      expect(LxScriptSourcesStore.deletedBundledIds(box: box), isEmpty);
    });
  });

  group('LxScriptEngine.removeScript', () {
    test('bundled delete removes the file and persists the id', () async {
      final store = fileStore();
      await store.seedIfMissing(
        id: 'suyin',
        assetPath: 'assets/lx_scripts/suyin.js',
        assetLoader: (_) async => _dummyCode,
      );
      final engine = LxScriptEngine(
        dio: Dio(),
        assetLoader: (_) async => _dummyCode,
        fileStore: store,
      );
      addTearDown(engine.dispose);
      await engine.removeScript('suyin');
      expect(await store.read('suyin'), isNull);
      expect(LxScriptSourcesStore.isBundledDeleted('suyin'), isTrue);
      // Custom-script records are untouched by a bundled delete.
      expect(LxScriptSourcesStore.customScripts(box: box), isEmpty);
    });

    test('custom delete removes the record, not the deleted set',
        () async {
      await LxScriptSourcesStore.saveCustomScript(
        const LxCustomScript(
          id: 'custom:abc123',
          name: 'Custom',
          url: 'https://example.com/x.js',
          code: _dummyCode,
          addedAt: 0,
        ),
        box: box,
      );
      final engine = LxScriptEngine(
        dio: Dio(),
        assetLoader: (_) async => _dummyCode,
        fileStore: fileStore(),
      );
      addTearDown(engine.dispose);
      await engine.removeScript('custom:abc123');
      expect(LxScriptSourcesStore.customScripts(box: box), isEmpty);
      expect(
        LxScriptSourcesStore.deletedBundledIds(box: box),
        isEmpty,
      );
    });

    test('ensureInitialized never loads a deleted bundled script',
        () async {
      await LxScriptSourcesStore.markBundledDeleted('suyin', box: box);
      final engine = LxScriptEngine(
        dio: Dio(),
        assetLoader: (_) async => _dummyCode,
        fileStore: fileStore(),
      );
      addTearDown(engine.dispose);
      await engine.ensureInitialized();
      // suyin: no info at all (skipped before seeding/loading).
      expect(engine.script('suyin'), isNull);
      expect(
        await File('${tempDir.path}/suyin.js').exists(),
        isFalse,
      );
      // The other sixteen were attempted (failed infos on Linux — the
      // JS runtime factory throws without the native QuickJS lib).
      expect(engine.scripts.length, 16);
      for (final s in engine.scripts) {
        expect(s.loaded, isFalse, reason: s.id);
      }
      // A second init still does not resurrect it.
      final engine2 = LxScriptEngine(
        dio: Dio(),
        assetLoader: (_) async => _dummyCode,
        fileStore: fileStore(),
      );
      addTearDown(engine2.dispose);
      await engine2.ensureInitialized();
      expect(engine2.script('suyin'), isNull);
    });
  });
}
