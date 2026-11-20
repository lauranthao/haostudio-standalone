// App log page widget tests: render order, filters, share, clear,
// empty state, 完成 closes the page.
//
// The share sheet is a platform call, so the page takes an `onShare`
// seam: tests pass a recorder and prove the FILTERED entries are what
// gets shared. The default share_plus backend itself was verified
// against the real plugin channel in a throwaway test (the plugin
// writes the .txt to a temp file and invokes the share method).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/logging/app_log.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/app_log_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppLog.resetForTest();
  });

  tearDown(() {
    Get.reset();
    AppLog.resetForTest();
  });

  // Filter tab labels ("INFO", "ERROR", ...) collide with the level
  // badges on the cards — same text, different size (tab 13, badge 11).
  Finder tab(String label) => find.byWidgetPredicate(
        (w) => w is Text && w.data == label && w.style?.fontSize == 13,
      );
  Finder badge(String label) => find.byWidgetPredicate(
        (w) => w is Text && w.data == label && w.style?.fontSize == 11,
      );

  Future<void> pumpPage(
    WidgetTester tester, {
    Future<void> Function(String text)? onShare,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: AppLogPage(onShare: onShare),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders entries newest first with badges and timestamps',
      (tester) async {
    AppLog.info('first entry');
    AppLog.error('second entry');
    await pumpPage(tester);

    expect(find.text('first entry'), findsOneWidget);
    expect(find.text('second entry'), findsOneWidget);
    expect(badge('INFO'), findsOneWidget);
    expect(badge('ERROR'), findsOneWidget);
    // Newest first: the error entry sits above the info entry.
    final errorTop = tester.getTopLeft(find.text('second entry')).dy;
    final infoTop = tester.getTopLeft(find.text('first entry')).dy;
    expect(errorTop, lessThan(infoTop));
    // Timestamp format yyyy-MM-dd HH:mm:ss.SSS.
    expect(
      find.textContaining(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$')),
          findsNWidgets(2),
    );
  });

  testWidgets('filter tabs show only their level', (tester) async {
    AppLog.debug('debug line');
    AppLog.info('info line');
    AppLog.warn('warn line');
    AppLog.error('error line');
    await pumpPage(tester);

    await tester.tap(tab('ERROR'));
    await tester.pumpAndSettle();
    expect(find.text('error line'), findsOneWidget);
    expect(find.text('info line'), findsNothing);
    expect(find.text('debug line'), findsNothing);

    await tester.tap(tab('INFO'));
    await tester.pumpAndSettle();
    expect(find.text('info line'), findsOneWidget);
    expect(find.text('error line'), findsNothing);

    await tester.tap(tab('全部'));
    await tester.pumpAndSettle();
    expect(find.text('debug line'), findsOneWidget);
    expect(find.text('info line'), findsOneWidget);
    expect(find.text('warn line'), findsOneWidget);
    expect(find.text('error line'), findsOneWidget);
  });

  testWidgets('empty state renders 无日志', (tester) async {
    await pumpPage(tester);
    expect(find.text('无日志'), findsOneWidget);
  });

  testWidgets('share exports only the filtered entries as .txt',
      (tester) async {
    AppLog.info('info line');
    AppLog.error('error line');
    final sharedTexts = <String>[];
    await pumpPage(
      tester,
      onShare: (text) async => sharedTexts.add(text),
    );

    await tester.tap(tab('INFO'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pumpAndSettle();

    expect(sharedTexts, hasLength(1));
    expect(sharedTexts.single, contains('[INFO] info line'));
    expect(sharedTexts.single, isNot(contains('[ERROR] error line')));
  });

  testWidgets('clear empties the list after confirm', (tester) async {
    AppLog.info('info line');
    await pumpPage(tester);
    expect(find.text('info line'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('清空日志'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('info line'), findsNothing);
    expect(find.text('无日志'), findsOneWidget);
    expect(AppLog.entries, isEmpty);

    // The 已清空 snackbar leaves a dismiss timer pending at test end.
    Get.closeAllSnackbars();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('clear cancel keeps the entries', (tester) async {
    AppLog.info('info line');
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('info line'), findsOneWidget);
    expect(AppLog.entries, hasLength(1));
  });

  testWidgets('完成 closes the page', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Get.to(() => const AppLogPage()),
              child: const Text('open log'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open log'));
    await tester.pumpAndSettle();
    expect(find.byType(AppLogPage), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AppLogPage), findsNothing);
    expect(find.text('open log'), findsOneWidget);
  });
}
