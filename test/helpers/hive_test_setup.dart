// Shared Hive widget-test setup (P1-T1).
//
// Why this exists: Hive does REAL disk I/O, and a widget test runs
// under fake async — a real I/O future never resolves inside the fake
// zone, so a test that awaits Hive work through `pumpAndSettle` (or
// through an awaited `box.close()` in tearDownAll) hangs forever.
// The rules for Hive-backed widget tests:
//
// - setUpAll: [HiveTestSetup.init] — temp dir + path_provider mock +
//   `HiveStore.init()`. One init per file (each test file runs in its
//   own process, so there is no cross-file box to share).
// - tearDownAll: [HiveTestSetup.dispose] — the box close is
//   fire-and-forget (`unawaited`): pending Hive writes never resolve
//   in the fake zone, so awaiting close() hangs tearDownAll. The temp
//   dir is deleted right after anyway.
// - Never `pumpAndSettle`: a live ticker/timer (danmaku, progress,
//   recovery prefetch) never lets it return. Use [pumpFor] (bounded
//   fake-time pump) or [settle] (real async drain via runAsync) instead.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/storage/hive_store.dart';

class HiveTestSetup {
  HiveTestSetup._();

  /// Temp Documents dir + path_provider mock + `HiveStore.init()`.
  /// Returns the temp dir; pass it to [dispose] in tearDownAll.
  static Future<Directory> init({String prefix = 'hao-hive-test-'}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp(prefix);
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return dir.path;
      }
      return null;
    });
    await HiveStore.init();
    return dir;
  }

  /// Fire-and-forget box close (never await it — see the file header)
  /// + delete the temp dir.
  static Future<void> dispose(Directory dir) async {
    unawaited(HiveStore.box.close());
    await dir.delete(recursive: true);
  }
}

/// Let real async work drain: the page awaits Hive writes and a widget
/// test's fake clock never drains real async I/O on its own. Without
/// this, Hive-backed loads stall and the page never resolves.
Future<void> settle(
  WidgetTester tester, [
  Duration duration = const Duration(milliseconds: 200),
]) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(duration);
  });
  await tester.pump();
}

/// Drain fire-and-forget Hive writes issued by a page under test
/// (e.g. LiveRoomPage records history + persists the quality choice
/// + writes crash breadcrumbs with `unawaited` puts).
///
/// Why a plain [settle] does NOT do this (bisected 2026-11-21 with a
/// minimal repro): hive_ce serialises backend writes through one
/// `ReadWriteSync` queue, and a write whose task started in the fake
/// zone leaves the queue stuck for the NEXT test — its first Hive
/// write hangs forever, even through runAsync. Draining takes one
/// settle per queued write (the runAsync lets that write's I/O land,
/// the pump runs its continuation and starts the next write), so this
/// loops settle + a short-timeout `box.flush()` probe until the flush
/// succeeds (flush goes through the same queue, so success means the
/// queue is empty). Must run INSIDE the test body (before the test
/// ends — the fake zone is discarded with the test, and a write left
/// pending then can never complete).
Future<void> drainHiveWrites(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await settle(tester);
    var timedOut = false;
    await tester.runAsync(
      () => HiveStore.box.flush().timeout(
        const Duration(seconds: 1),
        onTimeout: () => timedOut = true,
      ),
    );
    if (!timedOut) return;
  }
  // Still stuck after 10 rounds: leave it — the next test's first
  // Hive write will hang and say so. (Has not happened in practice;
  // a room issues ~8 breadcrumb/history writes at most.)
}

/// Bounded settle: pumps [duration] of fake time, then one more frame.
/// The replacement for `pumpAndSettle` — a live ticker/timer never
/// lets `pumpAndSettle` return.
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  await tester.pump(duration);
  await tester.pump();
}
