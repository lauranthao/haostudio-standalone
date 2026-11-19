// LX script engine UAF / cross-talk regression tests (v1.1.3).
//
// Runs entirely on the Linux host with a fake JS runtime + fake Dio:
// no native QuickJS lib needed. Each test drives a real race the
// production code must survive:
//
// - P1-2: an HTTP request in flight while its script is deleted must
//   never deliver into the disposed runtime (no __haoLxDeliver /
//   __haoLxDispatchResult evaluate after dispose).
// - Slow `inited` (>1s, e.g. 念心 4–5s) must load, not be disposed;
//   a script that never sends `inited` still fails bounded, and a
//   late `inited` arriving after dispose is dropped, never evaluated.
// - removeScript must not disturb the other scripts' runtimes, and a
//   re-load must not let the old runtime's dispose unregister the new
//   one.
// - flutter_js static-callback cross-talk (JSCore): messages stamped
//   for script A but delivered to the NEWEST runtime's handlers must
//   be routed to A (LxSend / LxRequest / LxLog / LxTimeout), never
//   land in the newest runtime and never touch a removed script.
//
// The fake runtime simulates the JSCore static dispatch by letting
// the test emit a message through ANY runtime's registered handler —
// the newest one's, as production does — and asserting where it lands.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';

import 'lx_fake_dio.dart';

/// Distinct script body per [n] (content hash => distinct script id).
String _tinyScript(int n) => '''
// @name TestScript$n
// @version 1.0.0
// variant $n
const { EVENT_NAMES, request, on, send } = globalThis.lx;
on(EVENT_NAMES.request, ({ action, source, info }) => {
  if (action === 'musicUrl') return Promise.resolve('https://example.com/x.mp3');
  return Promise.reject(new Error('nope'));
});
send(EVENT_NAMES.inited, { status: true, sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] } } });
''';

const String _initedDataJson =
    '{"status":true,"sources":{"wy":{"name":"wy","type":"music",'
    '"actions":["musicUrl"],"qualitys":["128k","320k"]}}}';

Map<String, dynamic> _initedPayload() =>
    jsonDecode(_initedDataJson) as Map<String, dynamic>;

/// Fake JS runtime: never executes JS. Records every evaluate (short
/// tag, so assertions can prove what did / did not run after a
/// dispose) and lets the test emit channel messages through its
/// registered handlers, exactly as the flutter_js static bridge does
/// on iOS (all messages land in the newest runtime's handlers).
class _RaceFakeRuntime extends JavascriptRuntime {
  _RaceFakeRuntime({
    this.initedDelay = const Duration(milliseconds: 10),
    this.emitRequestOnDispatch = false,
    this.slowUrl = 'https://slow.example.com/api',
  });

  final Duration? initedDelay;
  final bool emitRequestOnDispatch;
  final String slowUrl;

  final Map<String, Function(dynamic)> _handlers = {};
  final List<String> evalLog = [];
  bool disposed = false;
  String? scriptId;
  bool _initedScheduled = false;

  /// Deliver a channel message through THIS runtime's registered
  /// handler (simulates the static JSCore bridge delivering a
  /// message stamped for another script to the newest runtime).
  void emit(String channel, Map<String, dynamic> args) {
    _handlers[channel]?.call(args);
  }

  String _tag(String code) {
    if (code == kLxPrelude) return '<prelude>';
    if (code.length > 200) return '<script-body:${code.length}>';
    return code;
  }

  @override
  void initChannelFunctions() {}

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    evalLog.add(_tag(code));
    if (code == kLxPrelude) return JsEvalResult('1', null);
    if (code.startsWith('globalThis.__haoLxScriptId')) {
      final m = RegExp(r'"([^"]+)"').firstMatch(code);
      scriptId = m?.group(1);
      return JsEvalResult('1', null);
    }
    if (code.startsWith('__haoLxDispatch(')) {
      if (emitRequestOnDispatch) {
        emit('LxRequest', {
          'scriptId': scriptId,
          'id': 1,
          'url': slowUrl,
          'method': 'GET',
          'headers': <String, String>{},
          'body': null,
          'timeout': 0,
        });
      }
      return JsEvalResult('1', null);
    }
    if (code.startsWith('__haoLxDispatchResult(')) {
      return JsEvalResult(
        '{"done":true,"ok":true,"value":"https://example.com/x.mp3"}',
        null,
      );
    }
    if (code.startsWith('__haoLxDeliver(')) return JsEvalResult('ok', null);
    if (code.startsWith('__haoLxFireTimeout(')) {
      return JsEvalResult('ok', null);
    }
    // Script body: schedule the deferred `inited` delivery.
    if (initedDelay != null && !_initedScheduled) {
      _initedScheduled = true;
      Timer(initedDelay!, () {
        emit('LxSend', {
          'scriptId': scriptId,
          'event': 'inited',
          'data': _initedPayload(),
        });
      });
    }
    return JsEvalResult('1', null);
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) async =>
      evaluate(code, sourceUrl: sourceUrl);

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) =>
      JsEvalResult('null', null);

  @override
  T? convertValue<T>(JsEvalResult jsValue) => null;

  @override
  String jsonStringify(JsEvalResult jsValue) => 'null';

  @override
  int executePendingJob() => 0;

  @override
  void dispose() {
    disposed = true;
  }

  @override
  bool setupBridge(String channelName, Function(dynamic args) fn) {
    _handlers[channelName] = fn;
    return true;
  }

  @override
  String getEngineInstanceId() => 'fake-${identityHashCode(this)}';

  @override
  void setInspectable(bool inspectable) {}
}

/// Dio whose [slowUrl] request blocks on [gate] (lets the test delete
/// the script mid-flight); every other URL answers 200 immediately.
Dio _gatedDio({
  required List<String> log,
  required String slowUrl,
  required Completer<void> gate,
  required void Function() onSlowStarted,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final url = options.uri.toString();
        log.add(url);
        if (url == slowUrl) {
          onSlowStarted();
          await gate.future;
        }
        handler.resolve(
          Response<String>(
            requestOptions: options,
            statusCode: 200,
            data: '{"code":200,"url":"https://cdn.example.com/slow.mp3"}',
            headers: Headers.fromMap(
              {'content-type': ['application/json']},
            ),
          ),
        );
      },
    ),
  );
  return dio;
}

Future<void> _waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for condition');
    }
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P1-2 _pumpHttp dispose race', () {
    test('in-flight HTTP dropped after removeScript, never delivered',
        () async {
      const slowUrl = 'https://slow.example.com/api';
      final gate = Completer<void>();
      var slowStarted = false;
      final dioLog = <String>[];
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        dio: _gatedDio(
          log: dioLog,
          slowUrl: slowUrl,
          gate: gate,
          onSlowStarted: () => slowStarted = true,
        ),
        runtimeFactory: () {
          final f = _RaceFakeRuntime(
            slowUrl: slowUrl,
            emitRequestOnDispatch: true,
          );
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScriptFromFile(
        fileName: 'race.js',
        code: _tinyScript(1),
      );
      final fake = fakes.single;
      expect(info.loaded, isTrue);

      // Start a musicUrl lookup: the fake's dispatch emits the HTTP
      // job, _pumpHttp starts the (gated) Dio request.
      final urlFuture = engine.getMusicUrl(
        scriptId: info.id,
        platform: 'wy',
        song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
        quality: AudioQuality.q320k,
      );
      await _waitUntil(() => slowStarted);

      // Delete the script mid-flight, then let the HTTP finish.
      await engine.removeScript(info.id);
      expect(fake.disposed, isTrue);
      final evalsAtDispose = fake.evalLog.length;
      gate.complete();

      // The lookup must fail cleanly (requestAction throws '脚本已卸载',
      // getMusicUrl maps it to null) — not deliver into JS.
      expect(await urlFuture, isNull);
      expect(
        fake.evalLog.any((c) => c.startsWith('__haoLxDeliver(')),
        isFalse,
        reason: 'deliver must never evaluate on a disposed runtime',
      );
      expect(
        fake.evalLog.any((c) => c.startsWith('__haoLxDispatchResult(')),
        isFalse,
        reason: 'dispatch-result poll must stop after dispose',
      );
      // Nothing at all evaluated after the dispose point.
      expect(fake.evalLog.length, evalsAtDispose);
    });

    test('requestAction throws 脚本已卸载 when removed mid-flight',
        () async {
      const slowUrl = 'https://slow.example.com/api';
      final gate = Completer<void>();
      var slowStarted = false;
      final dioLog = <String>[];
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        dio: _gatedDio(
          log: dioLog,
          slowUrl: slowUrl,
          gate: gate,
          onSlowStarted: () => slowStarted = true,
        ),
        runtimeFactory: () {
          final f = _RaceFakeRuntime(
            slowUrl: slowUrl,
            emitRequestOnDispatch: true,
          );
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScriptFromFile(
        fileName: 'race2.js',
        code: _tinyScript(2),
      );
      final fake = fakes.single;

      final actionFuture = engine.requestAction(
        scriptId: info.id,
        action: 'musicUrl',
        source: 'wy',
        info: const {'musicInfo': <String, dynamic>{}, 'type': '320k'},
      );
      await _waitUntil(() => slowStarted);
      await engine.removeScript(info.id);
      gate.complete();

      await expectLater(
        actionFuture,
        throwsA(
          isA<LxScriptException>().having(
            (e) => e.message,
            'message',
            contains('脚本已卸载'),
          ),
        ),
      );
      expect(
        fake.evalLog.any((c) => c.startsWith('__haoLxDeliver(')),
        isFalse,
      );
    });

    test('slow inited (>1s) still loads instead of being disposed',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        runtimeFactory: () {
          final f = _RaceFakeRuntime(
            initedDelay: const Duration(milliseconds: 2500),
          );
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScriptFromFile(
        fileName: 'slow.js',
        code: _tinyScript(3),
      );
      expect(info.loaded, isTrue);
      expect(info.sources.map((s) => s.platform), ['wy']);
      expect(fakes.single.disposed, isFalse);
      expect(engine.script(info.id), isNotNull);
    });

    test('never-inited script fails bounded and late inited is dropped',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: (_) => {'status': 404, 'body': '{}'}, log: <String>[]),
        runtimeFactory: () {
          final f = _RaceFakeRuntime(
            initedDelay: const Duration(milliseconds: 2500),
          );
          fakes.add(f);
          return f;
        },
        initedTimeout: const Duration(seconds: 1),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine.addCustomScriptFromFile(
          fileName: 'never.js',
          code: _tinyScript(4),
        ),
        throwsA(isA<LxScriptException>()),
      );
      final fake = fakes.single;
      expect(fake.disposed, isTrue);
      expect(engine.scripts.where((s) => s.isCustom), isEmpty);
      // The 2.5s timer fires AFTER dispose: its LxSend must be
      // dropped by routing (runtime unregistered) — nothing may be
      // evaluated on the disposed runtime afterwards.
      final evalsAtDispose = fake.evalLog.length;
      await Future.delayed(const Duration(milliseconds: 2200));
      expect(fake.evalLog.length, evalsAtDispose);
    });
  });

  group('removeScript UAF (task 2)', () {
    test('removing one of five scripts leaves the other four alive',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(
          respond: (_) => {'status': 200, 'body': '{}'},
          log: <String>[],
        ),
        runtimeFactory: () {
          final f = _RaceFakeRuntime();
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        final info = await engine.addCustomScriptFromFile(
          fileName: 's$i.js',
          code: _tinyScript(10 + i),
        );
        ids.add(info.id);
        expect(info.loaded, isTrue);
      }
      expect(fakes.length, 5);

      await engine.removeScript(ids[2]);
      expect(fakes[2].disposed, isTrue);
      for (var i = 0; i < 5; i++) {
        if (i != 2) expect(fakes[i].disposed, isFalse, reason: 'fake $i');
      }
      expect(engine.script(ids[2]), isNull);
      for (var i = 0; i < 5; i++) {
        if (i != 2) expect(engine.script(ids[i])?.loaded, isTrue);
      }

      // A surviving script still resolves end to end.
      final url = await engine.getMusicUrl(
        scriptId: ids[0],
        platform: 'wy',
        song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
        quality: AudioQuality.q320k,
      );
      expect(url, 'https://example.com/x.mp3');
      // The removed one resolves to nothing.
      expect(
        await engine.getMusicUrl(
          scriptId: ids[2],
          platform: 'wy',
          song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
          quality: AudioQuality.q320k,
        ),
        isNull,
      );
    });

    test('re-load does not let the old dispose unregister the new runtime',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        runtimeFactory: () {
          final f = _RaceFakeRuntime();
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final first = await engine.addCustomScriptFromFile(
        fileName: 'reload.js',
        code: _tinyScript(20),
      );
      final second = await engine.addCustomScriptFromFile(
        fileName: 'reload.js',
        code: _tinyScript(20),
      );
      expect(second.id, first.id);
      expect(fakes.length, 2);
      expect(fakes[0].disposed, isTrue);
      expect(fakes[1].disposed, isFalse);

      // A message stamped for this id still lands in the NEW runtime,
      // even when it arrives through the OLD runtime's handler (the
      // static-bridge case): the old handler forwards, never touches
      // its disposed JS.
      fakes[0].emit('LxLog', {
        'scriptId': first.id,
        'level': 'log',
        'text': 'hello-new',
      });
      expect(engine.logsFor(first.id), contains('hello-new'));
      expect(
        fakes[0].evalLog.any((c) => c.startsWith('__haoLx')),
        isFalse,
      );
    });
  });

  group('multi-runtime message routing (task 3)', () {
    test('stamped messages via the newest runtime route to their owner',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(
          respond: (url) => url.contains('routed.example.com')
              ? {'status': 200, 'body': '{"ok":true}'}
              : {'status': 404, 'body': '{}'},
          log: <String>[],
        ),
        runtimeFactory: () {
          final f = _RaceFakeRuntime();
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final a = await engine.addCustomScriptFromFile(
        fileName: 'a.js',
        code: _tinyScript(30),
      );
      final b = await engine.addCustomScriptFromFile(
        fileName: 'b.js',
        code: _tinyScript(31),
      );
      final fakeA = fakes[0];
      final fakeB = fakes[1];
      expect(a.id, isNot(b.id));

      // Simulate the JSCore static bridge: EVERYTHING arrives at the
      // newest runtime's (B's) handlers — stamped for A.
      fakeB.emit('LxSend', {
        'scriptId': a.id,
        'event': 'updateAlert',
        'data': {'log': 'v99 available'},
      });
      expect(engine.lastUpdateAlert(a.id)?['log'], 'v99 available');
      expect(engine.lastUpdateAlert(b.id), isNull);

      fakeB.emit('LxLog', {
        'scriptId': a.id,
        'level': 'log',
        'text': 'a-log-line',
      });
      expect(engine.logsFor(a.id), contains('a-log-line'));
      expect(engine.logsFor(b.id), isEmpty);

      // An HTTP job stamped for A lands in A's queue (not B's): A's
      // next requestAction pumps it through Dio and delivers it to A.
      fakeB.emit('LxRequest', {
        'scriptId': a.id,
        'id': 9,
        'url': 'https://routed.example.com/job',
        'method': 'GET',
        'headers': <String, String>{},
        'body': null,
        'timeout': 0,
      });
      final v = await engine.requestAction(
        scriptId: a.id,
        action: 'musicUrl',
        source: 'wy',
        info: const {'musicInfo': <String, dynamic>{}, 'type': '320k'},
      );
      expect(v, 'https://example.com/x.mp3');
      expect(
        fakeA.evalLog.any((c) => c.startsWith('__haoLxDeliver(9,')),
        isTrue,
        reason: 'A must deliver its own routed job',
      );
      expect(
        fakeB.evalLog.any((c) => c.startsWith('__haoLxDeliver(')),
        isFalse,
        reason: 'B must never deliver A\'s job',
      );

      // Unstamped (legacy) messages still fall back to the receiving
      // runtime itself.
      fakeB.emit('LxLog', {'level': 'log', 'text': 'b-log-line'});
      expect(engine.logsFor(b.id), contains('b-log-line'));
      expect(engine.logsFor(a.id), isNot(contains('b-log-line')));

      // Stamped for an unknown / removed script is dropped everywhere.
      fakeB.emit('LxLog', {
        'scriptId': 'custom:gone',
        'level': 'log',
        'text': 'ghost',
      });
      expect(engine.logsFor(a.id), isNot(contains('ghost')));
      expect(engine.logsFor(b.id), isNot(contains('ghost')));
    });

    test('LxTimeout fires on the owner only, dropped after removal',
        () async {
      final fakes = <_RaceFakeRuntime>[];
      final engine = LxScriptEngine(
        runtimeFactory: () {
          final f = _RaceFakeRuntime();
          fakes.add(f);
          return f;
        },
      );
      addTearDown(engine.dispose);
      final a = await engine.addCustomScriptFromFile(
        fileName: 'ta.js',
        code: _tinyScript(40),
      );
      await engine.addCustomScriptFromFile(
        fileName: 'tb.js',
        code: _tinyScript(41),
      );
      final fakeA = fakes[0];
      final fakeB = fakes[1];

      // Timer for A, announced through B's handler (static bridge).
      fakeB.emit('LxTimeout', {
        'scriptId': a.id,
        'action': 'set',
        'timeoutIndex': '7',
        'timeout': 50,
      });
      await Future.delayed(const Duration(milliseconds: 200));
      expect(
        fakeA.evalLog,
        contains("__haoLxFireTimeout('7')"),
        reason: 'timer must fire on its owning runtime',
      );
      expect(
        fakeB.evalLog.any((c) => c.contains('__haoLxFireTimeout')),
        isFalse,
        reason: 'timer must never fire in the newest runtime',
      );

      // A pending timer is cancelled when its script is removed.
      fakeB.emit('LxTimeout', {
        'scriptId': a.id,
        'action': 'set',
        'timeoutIndex': '8',
        'timeout': 300,
      });
      await engine.removeScript(a.id);
      expect(fakeA.disposed, isTrue);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(
        fakeA.evalLog,
        isNot(contains("__haoLxFireTimeout('8')")),
        reason: 'disposed runtime must never fire a pending timer',
      );

      // A timer announced for the removed script after removal is
      // dropped outright (routing finds no registered owner).
      final evalsAfterRemove = fakeA.evalLog.length;
      fakeB.emit('LxTimeout', {
        'scriptId': a.id,
        'action': 'set',
        'timeoutIndex': '9',
        'timeout': 10,
      });
      await Future.delayed(const Duration(milliseconds: 100));
      expect(fakeA.evalLog.length, evalsAfterRemove);
    });
  });
}
