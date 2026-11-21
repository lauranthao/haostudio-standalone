// 1.1.6 live: DanmakuSettings fine settings (stroke / speed /
// max count / colour mode) — pure Hive-backed getter/setter tests,
// no widgets. Defaults + clamping + persistence, incl. the flying
// cap clamped to the engine object-pool ceiling (72).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/settings/source_stores.dart';

import 'helpers/hive_test_setup.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-116-danmaku-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  Future<void> clearKeys() async {
    for (final key in [
      HiveKeys.danmakuStroke,
      HiveKeys.danmakuStrokeWidth,
      HiveKeys.danmakuSpeed,
      HiveKeys.danmakuMaxCount,
      HiveKeys.danmakuColorMode,
    ]) {
      await HiveStore.box.delete(key);
    }
  }

  group('DanmakuSettings fine settings (1.1.6)', () {
    test('defaults match the engine defaults', () async {
      await clearKeys();
      expect(DanmakuSettings.stroke(), isTrue);
      expect(DanmakuSettings.strokeWidth(), 1.0);
      expect(DanmakuSettings.speed(), 1.0);
      expect(DanmakuSettings.flyingBaseSpeed(), 120.0);
      expect(DanmakuSettings.maxCount(), 80);
      expect(DanmakuSettings.flyingMaxVisibleCount(), 72);
      expect(DanmakuSettings.colorMode(), 'uniform');
    });

    test('speed / stroke width clamp to 0.5..2.0 and persist', () async {
      await DanmakuSettings.setSpeed(3.0);
      expect(DanmakuSettings.speed(), 2.0);
      expect(DanmakuSettings.flyingBaseSpeed(), 240.0);
      await DanmakuSettings.setSpeed(0.1);
      expect(DanmakuSettings.speed(), 0.5);
      expect(DanmakuSettings.flyingBaseSpeed(), 60.0);
      await DanmakuSettings.setStrokeWidth(9.0);
      expect(DanmakuSettings.strokeWidth(), 2.0);
      await DanmakuSettings.setStrokeWidth(0.0);
      expect(DanmakuSettings.strokeWidth(), 0.5);
      await DanmakuSettings.setStroke(false);
      expect(DanmakuSettings.stroke(), isFalse);
      await DanmakuSettings.setStroke(true);
      expect(DanmakuSettings.stroke(), isTrue);
    });

    test('max count clamps to 20..200; flying cap clamps to pool 72',
        () async {
      await DanmakuSettings.setMaxCount(500);
      expect(DanmakuSettings.maxCount(), 200);
      expect(DanmakuSettings.flyingMaxVisibleCount(), 72);
      await DanmakuSettings.setMaxCount(5);
      expect(DanmakuSettings.maxCount(), 20);
      expect(DanmakuSettings.flyingMaxVisibleCount(), 20);
      await DanmakuSettings.setMaxCount(50);
      expect(DanmakuSettings.maxCount(), 50);
      expect(DanmakuSettings.flyingMaxVisibleCount(), 50);
    });

    test('colour mode: platform sticks, bogus falls back to uniform',
        () async {
      await DanmakuSettings.setColorMode('platform');
      expect(DanmakuSettings.colorMode(), 'platform');
      await DanmakuSettings.setColorMode('bogus');
      expect(DanmakuSettings.colorMode(), 'uniform');
    });
  });
}
