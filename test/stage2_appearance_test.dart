// Stage 2 items 5-6 — wallpaper + background colour (AppearanceStore).
//
// File copies go to a temp documents dir; the index lives in a
// throwaway Hive box. Priority wallpaper > colour > theme default
// is checked through [AppearanceStore.backgroundActive] /
// [hasActiveWallpaper] / [hasActiveBackgroundColor].

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/appearance_store.dart';

void main() {
  late Box<dynamic> box;
  late Directory docs;
  late Directory srcDir;
  late AppearanceStore store;

  setUp(() async {
    Hive.init('test/.hive-stage2-appearance');
    box = await Hive.openBox<dynamic>('stage2_appearance_test');
    await box.clear();
    HiveStore.setTestBox(box);
    docs = await Directory.systemTemp.createTemp('hao_appear_');
    srcDir = await Directory.systemTemp.createTemp('hao_appear_src_');
    store = AppearanceStore(documentsDir: docs);
  });

  tearDown(() async {
    Get.reset();
    await box.close();
    await Hive.deleteBoxFromDisk('stage2_appearance_test');
    if (await docs.exists()) await docs.delete(recursive: true);
    if (await srcDir.exists()) await srcDir.delete(recursive: true);
  });

  Future<File> srcFile(String name, String bytes) async {
    final f = File('${srcDir.path}/$name');
    await f.writeAsString(bytes);
    return f;
  }

  group('parseHex', () {
    test('accepts #RRGGBB, rejects everything else', () {
      expect(AppearanceStore.parseHex('#FF0000'), const Color(0xFFFF0000));
      expect(AppearanceStore.parseHex('#000000'), const Color(0xFF000000));
      expect(AppearanceStore.parseHex('#abcdef'), const Color(0xFFABCDEF));
      expect(AppearanceStore.parseHex('FF0000'), isNull);
      expect(AppearanceStore.parseHex('#FFF'), isNull);
      expect(AppearanceStore.parseHex('#GGGGGG'), isNull);
      expect(AppearanceStore.parseHex(''), isNull);
    });
  });

  group('wallpaper', () {
    test('add copies the image, lists it, apply selects + enables', () async {
      final path = await store.addWallpaper(
        await srcFile('wall.jpg', 'fake-jpeg'),
      );
      expect(path, isNotNull);
      expect(path!.startsWith('${docs.path}/wallpapers/'), isTrue);
      expect(await File(path).exists(), isTrue);
      expect(store.wallpaperPaths, [path]);
      expect(store.backgroundActive, isFalse); // added, not applied
      await store.applyWallpaper(path);
      expect(store.currentWallpaper, path);
      expect(store.wallpaperEnabled, isTrue);
      expect(store.hasActiveWallpaper, isTrue);
      expect(store.backgroundActive, isTrue);
    });

    test('non-image files are refused', () async {
      expect(
        await store.addWallpaper(await srcFile('note.txt', 'x')),
        isNull,
      );
      expect(store.wallpaperPaths, isEmpty);
    });

    test('delete removes file + list + clears current selection', () async {
      final a = await store.addWallpaper(await srcFile('a.png', 'a'));
      final b = await store.addWallpaper(await srcFile('b.png', 'b'));
      await store.applyWallpaper(a!);
      await store.deleteWallpaper(a);
      expect(await File(a).exists(), isFalse);
      expect(store.wallpaperPaths, [b]);
      expect(store.currentWallpaper, isEmpty);
      expect(store.hasActiveWallpaper, isFalse);
      // The other wallpaper still exists and can be applied.
      await store.applyWallpaper(b!);
      expect(store.hasActiveWallpaper, isTrue);
    });

    test('switch off returns to theme default (files kept)', () async {
      final path = await store.addWallpaper(await srcFile('w.jpg', 'x'));
      await store.applyWallpaper(path!);
      await store.setWallpaperEnabled(false);
      expect(store.hasActiveWallpaper, isFalse);
      expect(store.backgroundActive, isFalse);
      expect(store.wallpaperPaths, [path]);
    });

    test('missing file is pruned from the list, never a phantom tile', () async {
      final path = await store.addWallpaper(await srcFile('gone.jpg', 'x'));
      await File(path!).delete();
      expect(store.wallpaperPaths, isEmpty);
    });
  });

  group('background colour', () {
    test('set stores + enables; invalid hex writes nothing', () async {
      expect(await store.setBackgroundColor('#1C1C1E'), isTrue);
      expect(store.backgroundHex, '#1C1C1E');
      expect(store.backgroundEnabled, isTrue);
      expect(store.hasActiveBackgroundColor, isTrue);
      expect(store.backgroundActive, isTrue);
      expect(await store.setBackgroundColor('not-a-colour'), isFalse);
      expect(store.backgroundHex, '#1C1C1E');
    });

    test('switch off / clear restores the theme default', () async {
      await store.setBackgroundColor('#000000');
      await store.setBackgroundEnabled(false);
      expect(store.hasActiveBackgroundColor, isFalse);
      expect(store.backgroundActive, isFalse);
      await store.setBackgroundEnabled(true);
      expect(store.backgroundActive, isTrue);
      await store.clearBackgroundColor();
      expect(store.backgroundHex, isEmpty);
      expect(store.backgroundEnabled, isFalse);
      expect(store.backgroundActive, isFalse);
    });

    test('wallpaper wins over background colour', () async {
      await store.setBackgroundColor('#000000');
      final path = await store.addWallpaper(await srcFile('w.jpg', 'x'));
      await store.applyWallpaper(path!);
      expect(store.backgroundActive, isTrue);
      expect(store.hasActiveWallpaper, isTrue);
      expect(store.hasActiveBackgroundColor, isTrue);
      await store.setWallpaperEnabled(false);
      // Wallpaper off -> the colour is still there underneath.
      expect(store.hasActiveWallpaper, isFalse);
      expect(store.backgroundActive, isTrue);
    });
  });

  group('AppearanceController', () {
    test('load() reflects the store in Rx values', () async {
      final path = await store.addWallpaper(await srcFile('w.jpg', 'x'));
      await store.applyWallpaper(path!);
      await store.setBackgroundColor('#FFFFFF');
      final controller = AppearanceController(store: store);
      await controller.load();
      expect(controller.wallpaperEnabled.value, isTrue);
      expect(controller.wallpaperPaths, [path]);
      expect(controller.currentWallpaper.value, path);
      expect(controller.backgroundEnabled.value, isTrue);
      expect(controller.backgroundHex.value, '#FFFFFF');
      expect(controller.backgroundActive.value, isTrue);
    });
  });

  group('wallpaper v1.1.5 migration', () {
    // The migration itself lives in main(), before load() — load()
    // keeps its contract (pure reflection, see the test above), so
    // the migration is tested on the store directly here.
    test('stored on -> off once; files + selection kept', () async {
      final path = await store.addWallpaper(await srcFile('wall.jpg', 'fake-jpeg'));
      await store.applyWallpaper(path!);
      expect(store.wallpaperEnabled, isTrue);
      await store.migrateWallpaperOffOnce();
      expect(store.wallpaperEnabled, isFalse);
      expect(store.currentWallpaper, path); // selection kept
      expect(store.wallpaperPaths, [path]); // files kept
      expect(store.backgroundActive, isFalse);
    });

    test('never runs twice: re-enabling after migration sticks', () async {
      await store.migrateWallpaperOffOnce();
      final path = await store.addWallpaper(await srcFile('w.jpg', 'x'));
      await store.applyWallpaper(path!);
      expect(store.wallpaperEnabled, isTrue);
      await store.migrateWallpaperOffOnce();
      expect(store.wallpaperEnabled, isTrue);
    });

    test('already off stays off', () async {
      expect(store.wallpaperEnabled, isFalse);
      await store.migrateWallpaperOffOnce();
      expect(store.wallpaperEnabled, isFalse);
    });
  });
}
