// Dynamic Type (build-29 typography): the app must honour the
// system text size — no textScaler override exists anywhere in lib/
// (grep: zero hits), and settings rows must not overflow when the
// user picks a large size. Pump a settings-like section at 2.0x and
// assert nothing overflows: in flutter_test an overflow is reported
// as a FlutterError and fails the test, and takeException() is the
// explicit check.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/hao_glass_button.dart';
import 'package:standalone/widgets/hao_inset_grouped.dart';
import 'package:standalone/widgets/settings_ui.dart';

void main() {
  Future<void> pumpSection(
    WidgetTester tester, {
    required double textScaler,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(textScaler),
              ),
              child: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const HaoSectionTitle('外观'),
                    HaoInsetGroupedSection(
                      child: Column(
                        children: [
                          ListTile(
                            title: const Text(
                              '这是一个很长的设置行标题用来测试大字体',
                            ),
                            subtitle: const Text(
                              '副标题也很长，放大后应当换行而不是溢出屏幕边缘',
                            ),
                            trailing: const Text('已开启'),
                            onTap: () {},
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          ListTile(
                            title: const Text('自定义强调色'),
                            subtitle: const Text('未安装'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {},
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    HaoGlassButton(
                      label: '清除全部缓存',
                      onPressed: () {},
                      fallback: FilledButton(
                        onPressed: () {},
                        child: const Text('清除全部缓存'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Dynamic Type', () {
    testWidgets('settings section lays out at 1.0x', (tester) async {
      await pumpSection(tester, textScaler: 1.0);
      expect(tester.takeException(), isNull);
      expect(find.text('外观'), findsOneWidget);
    });

    testWidgets('settings section does not overflow at 2.0x',
        (tester) async {
      await pumpSection(tester, textScaler: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('清除全部缓存'), findsOneWidget);
    });
  });
}
