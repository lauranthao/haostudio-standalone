// Stage 2 item 7 — custom font (CustomFontService + ThemeController).
//
// FontLoader is injected as a fake (records the bytes) so the tests
// never need a real font file or the native font loader; the service
// logic (copy, clear-old-after-success, Hive keys, restore) is what
// is under test. ThemeController checks that the family actually
// reaches ThemeData.fontFamily (the constructor route — copyWith
// has no fontFamily parameter, so this is the regression that would
// silently drop the font).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/services/custom_font_service.dart';

void main() {
  late Box<dynamic> box;
  late Directory docs;
  late Directory srcDir;

  setUp(() async {
    Hive.init('test/.hive-stage2-font');
    box = await Hive.openBox<dynamic>('stage2_font_test');
    await box.clear();
    HiveStore.setTestBox(box);
    docs = await Directory.systemTemp.createTemp('hao_font_');
    srcDir = await Directory.systemTemp.createTemp('hao_font_src_');
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('stage2_font_test');
    if (await docs.exists()) await docs.delete(recursive: true);
    if (await srcDir.exists()) await srcDir.delete(recursive: true);
  });

  Future<File> srcFile(String name) async {
    final f = File('${srcDir.path}/$name');
    await f.writeAsBytes(List<int>.generate(64, (i) => i));
    return f;
  }

  CustomFontService makeService({
    Future<void> Function(String, Uint8List)? register,
  }) {
    return CustomFontService(
      documentsDir: docs,
      register: register ?? (_, _) async {},
    );
  }

  test('install copies, registers and persists name + path', () async {
    final registered = <String>[];
    final service = makeService(
      register: (family, _) async => registered.add(family),
    );
    final family = await service.install(await srcFile('MyFont.ttf'));
    expect(family, CustomFontService.family);
    expect(registered, [CustomFontService.family]);
    expect(service.currentName, 'MyFont.ttf');
    expect(service.hasCustomFont, isTrue);
    final storedPath = HiveStore.getString(HiveKeys.customFontPath, '');
    expect(storedPath, isNotEmpty);
    expect(await File(storedPath).exists(), isTrue);
  });

  test('non-font files are refused and nothing is stored', () async {
    final service = makeService();
    expect(await service.install(await srcFile('note.txt')), isNull);
    expect(service.hasCustomFont, isFalse);
    expect(service.currentName, isEmpty);
  });

  test('failed registration keeps the old font untouched', () async {
    var fail = false;
    final service = makeService(
      register: (_, _) async {
        if (fail) throw StateError('bad font');
      },
    );
    final first = await service.install(await srcFile('Good.ttf'));
    expect(first, isNotNull);
    final firstPath = HiveStore.getString(HiveKeys.customFontPath, '');
    fail = true;
    expect(await service.install(await srcFile('Bad.otf')), isNull);
    // Old font still installed (name + file intact).
    expect(service.currentName, 'Good.ttf');
    expect(HiveStore.getString(HiveKeys.customFontPath, ''), firstPath);
    expect(await File(firstPath).exists(), isTrue);
  });

  test('installing a second font replaces the first', () async {
    final service = makeService();
    await service.install(await srcFile('First.ttf'));
    await service.install(await srcFile('Second.otf'));
    expect(service.currentName, 'Second.otf');
    final files = await Directory('${docs.path}/fonts').list().toList();
    expect(files.length, 1);
  });

  test('loadPersisted re-registers the stored font; clear restores default',
      () async {
    final registered = <String>[];
    final service = makeService(
      register: (family, bytes) async {
        registered.add(family);
        expect(bytes.length, 64);
      },
    );
    await service.install(await srcFile('Persist.ttf'));
    registered.clear();
    expect(await service.loadPersisted(), isTrue);
    expect(registered, [CustomFontService.family]);
    await service.clear();
    expect(service.hasCustomFont, isFalse);
    expect(service.currentName, isEmpty);
    expect(await service.loadPersisted(), isFalse);
    final files = await Directory('${docs.path}/fonts').list().toList();
    expect(files, isEmpty);
  });

  test('loadPersisted is false with nothing stored or file gone', () async {
    final service = makeService();
    expect(await service.loadPersisted(), isFalse);
    await service.install(await srcFile('Gone.ttf'));
    final path = HiveStore.getString(HiveKeys.customFontPath, '');
    await File(path).delete();
    expect(await service.loadPersisted(), isFalse);
  });

  group('ThemeController fontFamily', () {
    // ThemeData has no fontFamily getter (it is constructor-only and
    // baked into the default text themes), so the observable effect
    // is textTheme.bodyMedium.fontFamily.
    String? familyOf(ThemeData t) => t.textTheme.bodyMedium?.fontFamily;

    test('setCustomFontFamily reaches ThemeData text themes', () {
      final controller = ThemeController();
      // Default family is the platform default (Roboto in tests) —
      // the assertion is that it is NOT the custom family until set.
      expect(familyOf(controller.lightTheme), isNot(CustomFontService.family));
      controller.setCustomFontFamily(CustomFontService.family);
      expect(familyOf(controller.lightTheme), CustomFontService.family);
      expect(familyOf(controller.darkTheme), CustomFontService.family);
      // Switching theme keeps the font.
      controller.setTheme(HaoThemeId.darkGold);
      expect(familyOf(controller.lightTheme), CustomFontService.family);
      controller.setCustomFontFamily('');
      expect(familyOf(controller.lightTheme), isNot(CustomFontService.family));
    });
  });
}
