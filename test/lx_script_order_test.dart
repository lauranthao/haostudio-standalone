// LX script manual order (chen 2026-11-18): drag to reorder in
// 音源管理， saved to Hive (`hao_lx_order`), and honoured by the
// resolver between two LX script jobs.
//
// - store: save order -> read back -> close/reopen the box
//   (restart) -> order still there; saving the same script id
//   twice (re-import) leaves one record.
// - resolver: with a fake engine offering two script jobs, the
//   first-playable-wins resolve returns the URL of whichever
//   script the manual order puts first; a cooled script job still
//   goes last despite the manual order.
//
// Runs on the Linux host: fake script jobs (no JS runtime) and a
// fake Dio answering empty bodies for every built-in resolver.
//
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/lx_script_order_test.dart

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/lx_script_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

/// Fake engine: offers exactly the script jobs given, in list order.
/// The real engine is never initialised (no JS runtime on Linux).
class _FakeOrderEngine extends LxScriptEngine {
  _FakeOrderEngine(this.jobs, Dio dio)
      : super(
          dio: dio,
          assetLoader: (_) async => throw StateError('no assets'),
        );

  final List<({String key, String name, Future<({String url, AudioQuality? actualQuality})> Function() fn})> jobs;

  @override
  List<({String key, String name, Future<({String url, AudioQuality? actualQuality})> Function() fn})>
      scriptJobsFor(
    MusicPlatform platform,
    AudioQuality quality,
    Song song,
  ) =>
          jobs;
}

/// Dio answering an empty body for every request, so all built-in
/// resolvers return nothing and only the fake script jobs can win.
Dio _emptyDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

List<({String key, String name, Future<({String url, AudioQuality? actualQuality})> Function() fn})> _jobs(
  List<String> calls,
) => [
      (
        key: 'lx:aaa',
        name: 'AAA',
        fn: () async {
          calls.add('aaa');
          return (url: 'https://example.com/a.mp3', actualQuality: null);
        },
      ),
      (
        key: 'lx:bbb',
        name: 'BBB',
        fn: () async {
          calls.add('bbb');
          return (url: 'https://example.com/b.mp3', actualQuality: null);
        },
      ),
    ];

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-lx-order-');
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
      'test_order',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    try {
      await HiveStore.box.close();
    } catch (_) {}
    await hiveDir.delete(recursive: true);
  });

  // Fresh ranking state per test: speeds + manual order persist in
  // Hive across resolves, so clear them between tests.
  setUp(() async {
    await HiveStore.put('hao_resolver_speed', '');
    await HiveStore.put(HiveKeys.lxScriptOrder, '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  group('script order store', () {
    test('save and read back, survives close/reopen (restart)', () async {
      final box = await Hive.openBox<dynamic>('lx_order_restart');
      try {
        await LxScriptSourcesStore.saveScriptOrder(
          ['bbb', 'aaa'],
          box: box,
        );
        expect(
          LxScriptSourcesStore.scriptOrder(box: box),
          ['bbb', 'aaa'],
        );
      } finally {
        await box.close();
      }
      // Restart: close + reopen the same box file, order survives.
      final box2 = await Hive.openBox<dynamic>('lx_order_restart');
      try {
        expect(
          LxScriptSourcesStore.scriptOrder(box: box2),
          ['bbb', 'aaa'],
        );
      } finally {
        await box2.close();
      }
      await Hive.deleteBoxFromDisk('lx_order_restart');
    });

    test('saving the same script id twice leaves one record', () async {
      final box = await Hive.openBox<dynamic>('lx_order_dedup');
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        const script = LxCustomScript(
          id: 'custom:file:abc123',
          name: 'A',
          url: 'file://a.js',
          code: 'code-a',
          addedAt: 0,
        );
        await LxScriptSourcesStore.saveCustomScript(script, box: box);
        await LxScriptSourcesStore.saveCustomScript(
          LxCustomScript(
            id: script.id,
            name: script.name,
            url: script.url,
            code: script.code,
            addedAt: now,
          ),
          box: box,
        );
        final saved = LxScriptSourcesStore.customScripts(box: box);
        expect(saved.length, 1);
        expect(saved.first.id, 'custom:file:abc123');
      } finally {
        await box.close();
      }
      await Hive.deleteBoxFromDisk('lx_order_dedup');
    });
  });

  group('resolver honours manual order', () {
    MusicResolvers resolvers(List<String> calls) {
      final dio = _emptyDio();
      return MusicResolvers(
        dio: dio,
        scriptEngine: _FakeOrderEngine(_jobs(calls), dio),
      );
    }

    test('no manual order: script jobs keep engine order', () async {
      final calls = <String>[];
      final r = resolvers(calls);
      final res = await r.resolvePlayUrl(
        'order-1',
        MusicPlatform.wy,
        AudioQuality.q320k,
        'test',
      );
      expect(res, isNotNull);
      expect(res!.url, 'https://example.com/a.mp3');
      expect(res.via, 'AAA');
      expect(calls, ['aaa']);
    });

    test('manual order puts bbb first', () async {
      await LxScriptSourcesStore.saveScriptOrder(['bbb', 'aaa']);
      final calls = <String>[];
      final r = resolvers(calls);
      final res = await r.resolvePlayUrl(
        'order-2',
        MusicPlatform.wy,
        AudioQuality.q320k,
        'test',
      );
      expect(res, isNotNull);
      expect(res!.url, 'https://example.com/b.mp3');
      expect(res.via, 'BBB');
      expect(calls, ['bbb']);
    });

    test('cooled script job goes last despite manual order', () async {
      await LxScriptSourcesStore.saveScriptOrder(['bbb', 'aaa']);
      final calls = <String>[];
      final hanging =
          Completer<({String url, AudioQuality? actualQuality})>();
      final jobs = <({String key, String name, Future<({String url, AudioQuality? actualQuality})> Function() fn})>[
        (
          key: 'lx:aaa',
          name: 'AAA',
          fn: () async {
            calls.add('aaa');
            return (url: 'https://example.com/a.mp3', actualQuality: null);
          },
        ),
        (
          key: 'lx:bbb',
          name: 'BBB',
          fn: () {
            calls.add('bbb');
            return hanging.future;
          },
        ),
      ];
      final dio = _emptyDio();
      final r = MusicResolvers(
        dio: dio,
        scriptEngine: _FakeOrderEngine(jobs, dio),
      );
      // First resolve: bbb is first by manual order but hangs, so it
      // times out (2s) and is cooled; aaa wins.
      final first = await r.resolvePlayUrl(
        'order-3a',
        MusicPlatform.wy,
        AudioQuality.q320k,
        'test',
      );
      expect(first, isNotNull);
      expect(first!.url, 'https://example.com/a.mp3');
      expect(calls, ['bbb', 'aaa']);
      // Second resolve, same ranking state: bbb is cooled, so it
      // sorts last despite the manual order — aaa is tried first
      // and bbb is never reached.
      calls.clear();
      final second = await r.resolvePlayUrl(
        'order-3b',
        MusicPlatform.wy,
        AudioQuality.q320k,
        'test',
      );
      expect(second, isNotNull);
      expect(second!.url, 'https://example.com/a.mp3');
      expect(calls, ['aaa']);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
