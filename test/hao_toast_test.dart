// N-3 / D-5: HaoToast — top slide-down banner replacing Get.snackbar.
// - Appears below the status bar (top Positioned), glass card radius 14.
// - Title + optional message; kind icon inferred from the title.
// - Auto-dismisses after 2.5s by default; tap dismisses immediately.
// - Actions (retry / next) render as inline buttons and fire on tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/widgets/hao_toast.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    GetMaterialApp(
      theme: HaoThemes.of(HaoThemeId.appleGlass).light,
      home: const Scaffold(body: SizedBox()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(HaoToast.dismiss);

  testWidgets('banner appears at the top with title, message, icon',
      (tester) async {
    await _pumpApp(tester);
    HaoToast.show('已清除', message:  '全部缓存已清除');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已清除'), findsOneWidget);
    expect(find.text('全部缓存已清除'), findsOneWidget);
    // Success kind inferred from 已…: check icon, not the warning one.
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
    // Below the status bar: banner sits at the very top of the screen
    // (test viewport has no status-bar padding, so top == 8 + card
    // padding; on a real phone MediaQuery padding.top pushes it down).
    final top = tester.getTopLeft(find.text('已清除')).dy;
    expect(top, lessThan(100));
    HaoToast.dismiss();
  });

  testWidgets('failure title infers the warning icon', (tester) async {
    await _pumpApp(tester);
    HaoToast.show('下载失败', message:  '无法打开下载链接');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    HaoToast.dismiss();
  });

  testWidgets('auto-dismisses after 2.5s by default', (tester) async {
    await _pumpApp(tester);
    HaoToast.show('提示', message:  '下次打开生效');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('提示'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('提示'), findsNothing);
    expect(HaoToast.isShowing, isFalse);
  });

  testWidgets('explicit duration is honoured', (tester) async {
    await _pumpApp(tester);
    HaoToast.show('播放提示', message: 
      '加载失败',
      duration: const Duration(seconds: 4),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('播放提示'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('播放提示'), findsNothing);
  });

  testWidgets('tap dismisses immediately', (tester) async {
    await _pumpApp(tester);
    HaoToast.show('提示', message:  '下次打开生效');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('提示'));
    await tester.pump();
    expect(find.text('提示'), findsNothing);
  });

  testWidgets('actions render and fire, then dismiss', (tester) async {
    await _pumpApp(tester);
    var retried = false;
    HaoToast.show('播放提示', message: 
      '加载失败',
      actions: [
        HaoToastAction(label: '重试', onTap: () => retried = true),
        HaoToastAction(label: '下一首', onTap: () {}),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('下一首'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, isTrue);
    expect(find.text('播放提示'), findsNothing);
  });

  testWidgets('showing twice replaces the current banner', (tester) async {
    await _pumpApp(tester);
    HaoToast.show('提示', message:  '第一条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    HaoToast.show('提示', message:  '第二条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    HaoToast.dismiss();
  });
}
