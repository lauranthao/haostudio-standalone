// Music search history tests (v1.0.9 phone bug: 搜歌没有搜索记录).
//
// The search page had no history at all — no storage, no UI. The fix
// mirrors the video search page (VideoHistoryStore + _ChipSection):
// terms are saved to Hive on search start (newest first, dedup, cap
// 20, empty terms never recorded) and shown as chips before any
// search, with a clear entry. Tapping a chip re-runs that search.
//
// Hive setup mirrors live_quality_line_test.dart: temp dir + mocked
// path_provider + HiveStore.init + a MEMORY-backed test box, so Hive
// writes resolve inside widget tests (a file-backed box wedges in
// the fake-async zone — see the tearDownAll trap note below).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/song_search_page.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-search-hist-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return hiveDir.path;
          }
          return null;
        });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_search_history',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    // Trap (2026-11-17): never `await` box.close() in tearDownAll —
    // a pending Hive write queue in the fake zone makes close() never
    // return and hangs the whole file. Fire-and-forget is enough here;
    // the process ends with the file.
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await MusicStore.clearSearchHistory();
  });

  group('MusicStore search history', () {
    test('empty initially', () {
      expect(MusicStore.getSearchHistory(), isEmpty);
    });

    test('save + get, newest first', () async {
      await MusicStore.saveSearchQuery('周杰伦');
      await MusicStore.saveSearchQuery('林俊杰');
      expect(MusicStore.getSearchHistory(), ['林俊杰', '周杰伦']);
    });

    test('same term twice leaves one entry at the front', () async {
      await MusicStore.saveSearchQuery('周杰伦');
      await MusicStore.saveSearchQuery('林俊杰');
      await MusicStore.saveSearchQuery('周杰伦');
      expect(MusicStore.getSearchHistory(), ['周杰伦', '林俊杰']);
    });

    test('cap 20, oldest dropped', () async {
      for (var i = 0; i < 21; i++) {
        await MusicStore.saveSearchQuery('歌$i');
      }
      final history = MusicStore.getSearchHistory();
      expect(history.length, 20);
      expect(history.first, '歌20');
      expect(history, isNot(contains('歌0')));
    });

    test('empty / whitespace-only terms are never recorded', () async {
      await MusicStore.saveSearchQuery('');
      await MusicStore.saveSearchQuery('   ');
      await MusicStore.saveSearchQuery('  周杰伦  ');
      expect(MusicStore.getSearchHistory(), ['周杰伦']);
    });

    test('clear empties the history', () async {
      await MusicStore.saveSearchQuery('周杰伦');
      await MusicStore.clearSearchHistory();
      expect(MusicStore.getSearchHistory(), isEmpty);
    });

    test('corrupt stored JSON reads as empty, never throws', () async {
      await HiveStore.put(HiveKeys.musicSearchHist, 'not-json{{{');
      expect(MusicStore.getSearchHistory(), isEmpty);
    });
  });

  group('SongSearchPage history UI', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const SongSearchPage(),
        ),
      );
      await tester.pump();
    }

    testWidgets('empty history: no history section', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.text('搜索历史'), findsNothing);
      expect(find.text('清除'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('seeded history renders as chips with a clear entry', (
      tester,
    ) async {
      await MusicStore.saveSearchQuery('周杰伦');
      await MusicStore.saveSearchQuery('林俊杰');
      await pumpPage(tester);
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('林俊杰'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('清除'), findsOneWidget);
    });

    testWidgets('tap clear removes the whole section', (tester) async {
      await MusicStore.saveSearchQuery('周杰伦');
      await pumpPage(tester);
      expect(find.text('周杰伦'), findsOneWidget);
      await tester.tap(find.text('清除'));
      await tester.pump();
      expect(find.text('搜索历史'), findsNothing);
      expect(find.text('周杰伦'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(MusicStore.getSearchHistory(), isEmpty);
    });

    testWidgets('tap a chip fills the query and starts a search', (
      tester,
    ) async {
      await MusicStore.saveSearchQuery('周杰伦');
      await pumpPage(tester);
      // The tap fires a real search (network + 5 s timeout timers),
      // which must run in real async time — in the fake zone those
      // timers never fire and trip teardown's !timersPending check.
      await tester.runAsync(() async {
        await tester.tap(find.text('周杰伦'));
      });
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '周杰伦');
    });

    testWidgets('type tabs are a segmented control, not a dropdown (Beans)', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(
        find.byWidgetPredicate((w) => w is SegmentedButton),
        findsOneWidget,
      );
      expect(find.text('歌曲'), findsOneWidget);
      expect(find.text('歌单'), findsOneWidget);
      expect(find.text('歌手'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is DropdownButton), findsNothing);
    });

    testWidgets('search field has a magnifier and a clear button (Beans)', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsNothing);
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, isEmpty);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('per-chip × deletes just that term (Beans)', (tester) async {
      await MusicStore.saveSearchQuery('周杰伦');
      await MusicStore.saveSearchQuery('林俊杰');
      await pumpPage(tester);
      expect(find.text('林俊杰'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      // InputChip's default delete icon is Icons.clear (not cancel).
      await tester.tap(find.byIcon(Icons.clear).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('林俊杰'), findsNothing);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(MusicStore.getSearchHistory(), ['周杰伦']);
    });

    testWidgets('failed search shows an error with a retry button (Beans)', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField), '不存在的歌名xyz');
      // Real network in the VM fails fast (egress proxy rejects Dart
      // HTTP), so the stream settles with an error quickly.
      await tester.runAsync(() async {
        await tester.tap(find.text('搜索'));
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump();
      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}
