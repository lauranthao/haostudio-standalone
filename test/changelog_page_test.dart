// In-app update log page (chen 2026-11-20, Beans screenshot).
//
// - Every bundled version renders with its 新增功能 / 问题修复
//   sections (light + dark golden renders, eyeballed).
// - 完成 pops the page.
// Navigation from Settings (版本 row) is covered in
// test/settings_tab_page_test.dart, which owns the settings pump.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/app/changelog.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/changelog_page.dart';

// Same CJK font loader as the other render tests
// (render_tab_bar_pill_test.dart): widget-test fonts have no CJK
// glyphs, so goldens render Chinese as tofu without this.
Future<void> _loadCjkFont() async {
  final loader = FontLoader('NotoSansSC');
  for (final path in const [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ]) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  // AppBar title and TextButton text inherit their own theme slots,
  // not textTheme, so they stay tofu without these two overrides.
  final buttonStyle = base.textButtonTheme.style;

  // Button themes carry their own textStyle WITHOUT a fontFamily, and
  // a button's DefaultTextStyle shadows the ambient one — so button
  // labels would render in the Ahem test font (tofu) unless the
  // family is forced here too. On a real device the system font
  // covers them; this is test-only.
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  return base.copyWith(
    cupertinoOverrideTheme: haoCupertinoThemeWithFont('NotoSansSC'),
    textTheme: text,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle
          ?.copyWith(fontFamily: 'NotoSansSC'),
    ),
    textButtonTheme: TextButtonThemeData(
      style: buttonStyle?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final s = buttonStyle.textStyle?.resolve(states);
          return (s ?? const TextStyle()).copyWith(
            fontFamily: 'NotoSansSC',
          );
        }),
      ),
    ),

    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: cjkButton(base.segmentedButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cjkButton(base.outlinedButtonTheme.style),
    ),
  );
}

void main() {
  setUpAll(_loadCjkFont);

  Future<void> pumpPage(
    WidgetTester tester, {
    required ThemeData theme,
  }) async {
    // Tall viewport so all four cards lay out at once for the goldens
    // (1.1.6 added a fourth entry; 2400 no longer fits all of them —
    // ListView only builds on-screen children).
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: _cjkTheme(theme),
        home: const ChangelogPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders every version with both sections', (tester) async {
    await pumpPage(
      tester,
      theme: HaoThemes.of(HaoThemeId.appleGlass).light,
    );

    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    for (final entry in kChangelog) {
      expect(find.text(entry.version), findsOneWidget);
      expect(find.text(entry.title), findsOneWidget);
      for (final item in entry.features) {
        expect(find.text(item), findsOneWidget);
      }
      for (final item in entry.fixes) {
        expect(find.text(item), findsOneWidget);
      }
    }
    expect(find.text('新增功能'), findsNWidgets(kChangelog.length));
    expect(find.text('问题修复'), findsNWidgets(kChangelog.length));
  });

  testWidgets('完成 closes the page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChangelogPage(),
                  ),
                ),
                child: const Text('open log'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open log'));
    await tester.pumpAndSettle();
    expect(find.text('更新日志'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('open log'), findsOneWidget);
  });

  testWidgets('golden light', (tester) async {
    await pumpPage(
      tester,
      theme: HaoThemes.of(HaoThemeId.appleGlass).light,
    );
    await expectLater(
      find.byType(ChangelogPage),
      matchesGoldenFile('goldens/changelog_light.png'),
    );
  });

  testWidgets('golden dark', (tester) async {
    await pumpPage(
      tester,
      theme: HaoThemes.of(HaoThemeId.appleGlass).dark,
    );
    await expectLater(
      find.byType(ChangelogPage),
      matchesGoldenFile('goldens/changelog_dark.png'),
    );
  });
}
