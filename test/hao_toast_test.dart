// N-3 / D-5: HaoToast — top slide-down banner replacing Get.snackbar.
// - Appears below the status bar (top Positioned), glass card radius 14.
// - Title + optional message; kind icon inferred from the title.
// - Auto-dismisses after 2.5s by default; tap dismisses immediately.
// - Actions (retry / next) render as inline buttons and fire on tap.
import 'dart:math' as math;
import 'dart:ui' as ui;

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

  // J (chen 2026-11-22): 提示 / 下次打开生效两行字下的黄线。根因是
  // toast 经 raw OverlayEntry 插入、没有 Material 祖先，Text 回落到
  // WidgetsApp 的 _errorTextStyle（monospace + 黄色双下划线）。修法是
  // banner 内包一层透明 Material；此测试锁死：toast 渲染出的每个
  // span 都不带下划线、不带黄色、不带 monospace。
  testWidgets('toast texts never fall back to the yellow-underlined error style',
      (tester) async {
    await _pumpApp(tester);
    HaoToast.show('提示', message: '下次打开生效');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('提示'), findsOneWidget);
    expect(find.text('下次打开生效'), findsOneWidget);

    final richTexts = find
        .byType(RichText)
        .evaluate()
        .map((e) => e.widget as RichText)
        .toList();
    expect(richTexts, isNotEmpty);
    var checked = 0;
    void checkSpan(InlineSpan span) {
      if (span is TextSpan) {
        final style = span.style;
        if (style != null) {
          expect(style.decoration, anyOf(isNull, TextDecoration.none),
              reason: 'toast text must not be underlined');
          expect(style.decorationColor, isNot(Colors.yellow),
              reason: 'toast text must not carry the error-style yellow underline');
          expect(style.fontFamily, isNot('monospace'),
              reason: 'toast text must use the theme font, not the error fallback');
          checked++;
        }
        span.children?.forEach(checkSpan);
      }
    }

    for (final rt in richTexts) {
      checkSpan(rt.text);
    }
    expect(checked, greaterThanOrEqualTo(2));
    HaoToast.dismiss();
  });

  testWidgets('golden: toast over busy wallpaper at glass 0% has no yellow underline',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(
          HaoThemeId.appleGlass,
          glassIntensity: 0,
          backgroundActive: true,
        ).light,
        home: const Scaffold(
          body: _ToastBackdrop(child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    HaoToast.show('提示', message: '下次打开生效');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('下次打开生效'), findsOneWidget);
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/hao_toast_no_underline_glass0.png'),
    );
    HaoToast.dismiss();
  });
}

/// Painted busy wallpaper + the 0.55 theme scrim, exactly like the
/// production AppearanceBackgroundLayer (same seed-28 painter as the
/// b29 glass-0 goldens).
class _ToastBackdrop extends StatelessWidget {
  const _ToastBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    return SizedBox(
      width: 800,
      height: 600,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _ToastBusyPainter(), size: const Size(800, 600)),
          Container(
            color: theme.scaffoldBackground.withValues(alpha: 0.55),
          ),
          child,
        ],
      ),
    );
  }
}

class _ToastBusyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final random = math.Random(28);
    for (var i = 0; i < 240; i++) {
      final x = random.nextDouble() * (size.width - 40);
      final y = random.nextDouble() * (size.height - 40);
      final w = 20 + random.nextDouble() * 100;
      final h = 20 + random.nextDouble() * 100;
      canvas.drawRect(
        Rect.fromLTWH(x, y, w, h),
        Paint()
          ..color = Color.fromRGBO(
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
            1,
          ),
      );
    }
    final points = <Offset>[];
    for (var i = 0; i < 8000; i++) {
      points.add(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
      );
    }
    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ToastBusyPainter oldDelegate) => false;
}
