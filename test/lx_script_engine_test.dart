// LX script engine tests (M-P0-6 Part B).
//
// Runs the REAL flutter_js engine (JavaScriptCore on iOS, QuickJS
// elsewhere) against the REAL bundled asset scripts, with a fake Dio
// answering every HTTP call. Proves the JS engine + `lx` object +
// script evaluation work together end to end.
//
// NOTE: on the Linux test host these groups SKIP — the flutter_js
// native QuickJS library (libquickjs_c_bridge_plugin.so) is only
// built for iOS/Android targets, so `getJavascriptRuntime` throws
// there. The Dart-side logic is covered by master_quality_test.dart
// / music_modes_test.dart etc. On iOS the library ships with the app
// and these tests run for real (chen's phone test is the final
// confirmation).
// - prelude: bare `lx` alias, EVENT_NAMES, utils.buffer round-trips.
// - all 20 scripts load and send `inited` with exactly the capabilities
//   they declare (no more, no less).
// - ikun musicUrl end to end (master tier) via fake ikun API.
// - 溯音 search end to end (kw) via fake oiapi Kuwo.
// - 溯音 QQ musicUrl returns null without a key (its embedded shared
//   key was sanitised to '' — no key ships in the app).
// - custom-script URL flow: valid script loads, bad script fails and
//   is not saved.
// - ikun's checkUpdate (which uses bare `lx.EVENT_NAMES`) delivers an
//   updateAlert — proving the bare alias works.
//
// The engine is constructed per test with a fake Dio; Hive is NOT
// initialised in these tests, so script toggles / custom-script
// persistence silently fall back to defaults (store unit tests live
// in settings_stores_test.dart's style — see LxScriptSourcesStore
// tests below using a throwaway box).

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';

import 'lx_fake_dio.dart';

/// Tiny valid LX script used for the custom-URL flow test. Sends
/// showConfigView at load so the capture path is exercised too.
const String _tinyScript = '''
// @name TestScript
// @version 1.0.0
const { EVENT_NAMES, request, on, send } = globalThis.lx;
on(EVENT_NAMES.request, ({ action, source, info }) => {
  if (action === 'musicUrl') return Promise.resolve('https://example.com/x.mp3');
  return Promise.reject(new Error('nope'));
});
send(EVENT_NAMES.showConfigView, { title: 'Cfg' });
send(EVENT_NAMES.inited, { status: true, sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] } } });
''';

/// Script reporting a `{url, quality}` map instead of a bare URL
/// (P1-L1): at a master request it reports a flac-tier file, so the
/// resolver must label it hires, never master.
const String _mapScript = '''
// @name MapScript
// @version 1.0.0
const { EVENT_NAMES, request, on, send } = globalThis.lx;
on(EVENT_NAMES.request, ({ action, source, info }) => {
  if (action === 'musicUrl') return Promise.resolve({url: 'https://example.com/m.flac', quality: 'flac'});
  return Promise.reject(new Error('nope'));
});
send(EVENT_NAMES.inited, { status: true, sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac', 'master'] } } });
''';

/// Fake HTTP answers for every host the 4 scripts + tests touch.
Map<String, dynamic> _respond(String url) {
  // ikun update check (fires at load) — returns an update payload so
  // the bare-`lx` path is exercised.
  if (url.contains('api.ikunshare.com/script/lxmusic')) {
    return {
      'status': 200,
      'body':
          '{"code":200,"data":{"updateMsg":"v23 available","updateUrl":"https://example.com/ikun.js"}}',
    };
  }
  // ikun music URL.
  if (url.contains('api.ikunshare.com/url')) {
    return {
      'status': 200,
      'body': '{"code":200,"url":"https://cdn.example.com/master.flac"}',
    };
  }
  // 新澜 / 落雪 update checks — fail quietly.
  if (url.contains('checkUpdate=')) {
    return {'status': 404, 'body': '{"code":404}'};
  }
  // 溯音 kw search (oiapi Kuwo).
  if (url.contains('oiapi.net/api/Kuwo')) {
    return {
      'status': 200,
      'body':
          '{"data":{"song":"Test Song","singer":"Singer","album":"Alb","rid":"12345","time":"185"}}',
    };
  }
  // 溯音 wy musicUrl (oiapi Music_163).
  if (url.contains('oiapi.net/api/Music_163')) {
    return {
      'status': 200,
      'body':
          '{"code":0,"data":[{"url":"https://cdn.example.com/wy.mp3"}]}',
    };
  }
  // Custom-script download.
  if (url == 'https://example.com/custom.js') {
    return {'status': 200, 'body': _tinyScript};
  }
  if (url == 'https://example.com/map.js') {
    return {'status': 200, 'body': _mapScript};
  }
  if (url == 'https://example.com/bad.js') {
    return {'status': 200, 'body': 'this is not js {{{'};
  }
  // Deferred-inited script (tongyi UAF fix test): the fake runtime
  // below delivers `inited` 150ms after evaluate, the real script
  // never sends it at all — both go through the same download path.
  if (url == 'https://example.com/deferred.js' ||
      url == 'https://example.com/never.js') {
    return {'status': 200, 'body': _deferredScript};
  }
  return {'status': 404, 'body': '{}'};
}

/// Script body for the deferred-inited tests. The fake runtime never
/// executes it; it only needs to pass `addCustomScript`'s
/// `globalThis.lx` check and carry an `@name` for `_parseMeta`.
const String _deferredScript = '''
// @name DeferredScript
// @version 1.0.0
const { EVENT_NAMES, send } = globalThis.lx;
setTimeout(() => send(EVENT_NAMES.inited, { status: true, sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] } } }), 150);
''';

/// Fake JS runtime: never executes JS. `evaluate` of the prelude is a
/// no-op; `evaluate` of script code schedules a deferred `inited`
/// delivery after [initedDelay] (simulating a script like tongyi that
/// sends `inited` from a setTimeout). With [initedDelay] null, `inited`
/// is never delivered. Lets the deferred-inited wait be tested on the
/// Linux host, where the real flutter_js native lib does not exist.
class _FakeJsRuntime extends JavascriptRuntime {
  _FakeJsRuntime({this.initedDelay});

  final Duration? initedDelay;
  final Map<String, Function(dynamic)> _handlers = {};
  bool disposed = false;

  @override
  void initChannelFunctions() {}

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    if (code != kLxPrelude && initedDelay != null) {
      Timer(initedDelay!, () {
        _handlers['LxSend']?.call({
          'event': 'inited',
          'data': {
            'status': true,
            'sources': {
              'wy': {
                'name': 'wy',
                'type': 'music',
                'actions': ['musicUrl'],
                'qualitys': ['128k', '320k'],
              },
            },
          },
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

/// On the Linux test host the flutter_js native QuickJS library
/// (libquickjs_c_bridge_plugin.so) does not exist — it is only built
/// for iOS/Android targets — so `getJavascriptRuntime` throws and no
/// script can be evaluated. Skip the whole file there; the Dart-side
/// logic (quality mapping, scriptJobsFor, lxSongFromJson) is covered
/// by master_quality_test.dart / music_modes_test.dart etc. On iOS
/// the library ships with the app and these tests run for real.
final String? _linuxSkip = Platform.isLinux
    ? 'No QuickJS native lib on Linux test host (flutter_js .so is iOS/Android only)'
    : null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prelude (bare lx + utils)', () {
    test('lx object, bare alias, buffer round-trips', () async {
      final rt = getJavascriptRuntime(xhr: false);
      addTearDown(() {
        try {
          rt.dispose();
        } catch (_) {}
      });
      final pre = rt.evaluate(kLxPrelude);
      expect(pre.isError, isFalse, reason: pre.stringResult);
      expect(rt.evaluate('typeof lx').stringResult, 'object');
      expect(rt.evaluate('typeof globalThis.lx').stringResult, 'object');
      expect(
        rt.evaluate('lx.EVENT_NAMES.request').stringResult,
        'request',
      );
      expect(rt.evaluate('lx.env').stringResult, 'mobile');
      expect(
        rt
            .evaluate(
              'lx.utils.buffer.bufToString(lx.utils.buffer.from("hello","utf-8"),"base64")',
            )
            .stringResult,
        'aGVsbG8=',
      );
      expect(
        rt
            .evaluate(
              'lx.utils.buffer.bufToString(lx.utils.buffer.from("aGVsbG8=","base64"),"utf-8")',
            )
            .stringResult,
        'hello',
      );
      expect(
        rt
            .evaluate(
              'lx.utils.buffer.bufToString(lx.utils.buffer.from("你好","utf-8"),"utf-8")',
            )
            .stringResult,
        '你好',
      );
      expect(
        rt
            .evaluate(
              'lx.utils.buffer.bufToString(lx.utils.buffer.from("hi","utf-8"),"hex")',
            )
            .stringResult,
        '6869',
      );
    });
  }, skip: _linuxSkip);

  group('bundled scripts', () {
    late LxScriptEngine engine;
    late List<String> log;

    setUp(() async {
      log = <String>[];
      engine = LxScriptEngine(dio: buildFakeDio(respond: _respond, log: log));
      await engine.ensureInitialized();
    });

    tearDown(() => engine.dispose());

    test('all twenty load with exactly their declared capabilities', () {
      expect(engine.scripts.length, 20);
      for (final s in engine.scripts) {
        expect(s.loaded, isTrue, reason: '${s.id}: ${s.error}');
      }

      final ikun = engine.script('ikun')!;
      expect(ikun.version, isNotEmpty);
      expect(
        ikun.sources.map((s) => s.platform).toSet(),
        {'wy', 'kw', 'git'},
      );
      final ikunWy = ikun.sourceFor('wy')!;
      expect(ikunWy.actions, ['musicUrl']);
      expect(
        ikunWy.qualities,
        containsAll(['128k', '320k', 'flac', 'hires', 'master']),
      );

      final xinlan = engine.script('xinlan')!;
      expect(
        xinlan.sources.map((s) => s.platform).toSet(),
        {'kw', 'mg', 'kg', 'tx', 'wy'},
      );
      for (final s in xinlan.sources) {
        expect(s.actions, ['musicUrl']);
        expect(s.qualities, ['128k', '320k']);
      }

      final suyin = engine.script('suyin')!;
      expect(
        suyin.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'mg'},
      );
      expect(suyin.sourceFor('tx')!.actions, ['musicUrl']);
      expect(suyin.sourceFor('tx')!.qualities, contains('master'));
      expect(suyin.sourceFor('kw')!.actions, ['musicUrl', 'search']);
      expect(suyin.sourceFor('mg')!.actions, ['musicUrl', 'search']);
      expect(suyin.sourceFor('wy')!.actions, ['musicUrl']);

      final luoxue = engine.script('luoxue')!;
      // 'local' is filtered out — not a music platform.
      expect(
        luoxue.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy'},
      );
      expect(luoxue.sourceFor('wy')!.actions, ['musicUrl']);
      expect(luoxue.sourceFor('wy')!.qualities, contains('master'));

      // Verified live 2026-11-17 via the Node LX harness (real prelude
      // + real HTTP): both declare the same 5 platforms, musicUrl only.
      final fish = engine.script('fish')!;
      expect(fish.version, '1.9.0');
      expect(
        fish.sources.map((s) => s.platform).toSet(),
        {'kw', 'wy', 'kg', 'tx', 'mg'},
      );
      for (final s in fish.sources) {
        expect(s.actions, ['musicUrl']);
      }
      expect(fish.sourceFor('wy')!.qualities, ['128k', '320k', 'flac']);
      expect(
        fish.sourceFor('kw')!.qualities,
        contains('flac24bit'),
      );

      final jiexiang = engine.script('jiexiang')!;
      expect(jiexiang.version, '2.3.0');
      expect(
        jiexiang.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg'},
      );
      for (final s in jiexiang.sources) {
        expect(s.actions, ['musicUrl']);
      }
      expect(
        jiexiang.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac'],
      );
      expect(
        jiexiang.sourceFor('kg')!.qualities,
        containsAll(['128k', '320k', 'flac', 'hires', 'master']),
      );
      expect(
        jiexiang.sourceFor('kw')!.qualities,
        contains('flac24bit'),
      );

      // 14 scripts from chen's V261115 pack (2026-11-17) — verified
      // live via the Node LX harness (real prelude + real HTTP):
      // wy 320k returned a curl-verified MP3 for each one. 回避聚合
      // + stellarwave-v0.0.14 ship with their embedded keys sanitised
      // to '' and were re-verified still working after sanitising.
      final hyw = engine.script('hyw')!;
      expect(
        hyw.sources.map((s) => s.platform).toSet(),
        {'kw', 'tx', 'wy', 'mg', 'qs', 'bili', 'ytb', 'xm', 'kg'},
      );
      expect(hyw.sourceFor('wy')!.actions, ['musicUrl']);
      expect(
        hyw.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac', 'flac24bit'],
      );

      final helloworld = engine.script('helloworld')!;
      // 'local' is filtered out like luoxue's.
      expect(
        helloworld.sources.map((s) => s.platform).toSet(),
        {'kw', 'kg', 'tx', 'wy', 'mg'},
      );
      expect(helloworld.sourceFor('wy')!.actions, ['musicUrl']);
      expect(
        helloworld.sourceFor('wy')!.qualities,
        contains('master'),
      );

      final aya = engine.script('aya')!;
      expect(
        aya.sources.map((s) => s.platform).toSet(),
        {'wy', 'kw', 'kg', 'mg'},
      );
      expect(aya.sourceFor('wy')!.qualities, contains('master'));

      final gdstudio = engine.script('gdstudio')!;
      expect(
        gdstudio.sources.map((s) => s.platform).toSet(),
        {'wy', 'kw', 'tx', 'kg', 'mg'},
      );
      expect(
        gdstudio.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac', 'flac24bit'],
      );

      final yuningxi = engine.script('yuningxi')!;
      expect(
        yuningxi.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg'},
      );
      expect(yuningxi.sourceFor('wy')!.qualities, contains('master'));

      final stellarwave = engine.script('stellarwave')!;
      expect(
        stellarwave.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg', 'qs'},
      );
      expect(
        stellarwave.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac'],
      );

      final stellarwave014 = engine.script('stellarwave014')!;
      expect(
        stellarwave014.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg'},
      );
      expect(
        stellarwave014.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac', 'flac24bit'],
      );

      final xinghai = engine.script('xinghai')!;
      expect(
        xinghai.sources.map((s) => s.platform).toSet(),
        {'wy', 'tx', 'kg', 'kw', 'mg', 'qs'},
      );
      expect(xinghai.sourceFor('wy')!.qualities, contains('master'));
      expect(
        xinghai.sourceFor('wy')!.actions,
        containsAll(['musicUrl', 'lyric', 'pic']),
      );

      final huibi = engine.script('huibi')!;
      expect(
        huibi.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg'},
      );
      expect(huibi.sourceFor('wy')!.qualities, contains('master'));

      final molan = engine.script('molan')!;
      expect(
        molan.sources.map((s) => s.platform).toSet(),
        {'tx', 'wy', 'kw', 'kg', 'mg', 'qs', 'sd', 'joox'},
      );
      expect(
        molan.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac'],
      );

      final yuxi = engine.script('yuxi')!;
      expect(
        yuxi.sources.map((s) => s.platform).toSet(),
        {'wy', 'tx', 'kg', 'kw'},
      );
      expect(yuxi.sourceFor('wy')!.qualities, contains('master'));

      final kuliao = engine.script('kuliao')!;
      expect(
        kuliao.sources.map((s) => s.platform).toSet(),
        {'wy', 'tx', 'kw', 'kg', 'mg'},
      );
      expect(
        kuliao.sourceFor('wy')!.actions,
        containsAll(['search', 'musicUrl']),
      );
      expect(kuliao.sourceFor('wy')!.qualities, contains('hires'));

      final feichangdao = engine.script('feichangdao')!;
      expect(
        feichangdao.sources.map((s) => s.platform).toSet(),
        {'wy', 'tx', 'kw', 'kg', 'mg', 'qs'},
      );
      expect(
        feichangdao.sourceFor('wy')!.actions,
        containsAll(['search', 'musicUrl']),
      );

      final tongyi = engine.script('tongyi')!;
      expect(
        tongyi.sources.map((s) => s.platform).toSet(),
        {'kw', 'wy'},
      );
      expect(
        tongyi.sourceFor('wy')!.qualities,
        ['128k', '320k', 'flac'],
      );
    });

    test('scriptJobsFor only offers qualities the script declares', () {
      final song = Song(
        songId: '1851244158',
        title: 'Test',
        platform: MusicPlatform.wy,
      );
      final masterJobs = engine.scriptJobsFor(
        MusicPlatform.wy,
        AudioQuality.master,
        song,
      );
      // 溯音 wy declares only 128k/320k/flac — no master — so the
      // engine correctly excludes it at the master tier; only scripts
      // listing 'master' get a master job. Never substitute hires for
      // master. (V261115 adds helloworld/aya/yuningxi/xinghai/yuxi/
      // huibi to the master tier.)
      expect(
        masterJobs.map((j) => j.key).toSet(),
        {
          'lx:luoxue',
          'lx:helloworld',
          'lx:aya',
          'lx:yuningxi',
          'lx:xinghai',
          'lx:yuxi',
          'lx:huibi',
        },
      );
      final hiresJobs = engine.scriptJobsFor(
        MusicPlatform.wy,
        AudioQuality.hires,
        song,
      );
      // Every script except xinlan (128k/320k only) serves hires on wy.
      expect(
        hiresJobs.map((j) => j.key).toSet(),
        {
          'lx:suyin',
          'lx:luoxue',
          'lx:fish',
          'lx:jiexiang',
          'lx:hyw',
          'lx:helloworld',
          'lx:aya',
          'lx:gdstudio',
          'lx:yuningxi',
          'lx:stellarwave',
          'lx:stellarwave014',
          'lx:xinghai',
          'lx:huibi',
          'lx:molan',
          'lx:yuxi',
          'lx:kuliao',
          'lx:feichangdao',
          'lx:tongyi',
        },
      );
      final q320Jobs = engine.scriptJobsFor(
        MusicPlatform.wy,
        AudioQuality.q320k,
        song,
      );
      expect(
        q320Jobs.map((j) => j.key).toSet(),
        {
          'lx:xinlan',
          'lx:suyin',
          'lx:luoxue',
          'lx:fish',
          'lx:jiexiang',
          'lx:hyw',
          'lx:helloworld',
          'lx:aya',
          'lx:gdstudio',
          'lx:yuningxi',
          'lx:stellarwave',
          'lx:stellarwave014',
          'lx:xinghai',
          'lx:huibi',
          'lx:molan',
          'lx:yuxi',
          'lx:kuliao',
          'lx:feichangdao',
          'lx:tongyi',
        },
      );
      // 溯音 is no longer the only script declaring search: 裤佬SVIP
      // and 非常刀 declare search too (kw + wy).
      expect(
        engine.searchLegsFor(MusicPlatform.kw).map((l) => l.scriptId),
        ['suyin', 'kuliao', 'feichangdao'],
      );
      expect(
        engine.searchLegsFor(MusicPlatform.wy).map((l) => l.scriptId),
        ['kuliao', 'feichangdao'],
      );
    });

    test('ikun musicUrl end to end (master tier)', () async {
      final song = Song(
        songId: '1851244158',
        title: 'Test',
        platform: MusicPlatform.wy,
      );
      final url = await engine.getMusicUrl(
        scriptId: 'ikun',
        platform: 'wy',
        song: song,
        quality: AudioQuality.master,
      );
      expect(url, 'https://cdn.example.com/master.flac');
      // The script built the exact ikun request.
      expect(
        log.any(
          (u) =>
              u.contains('api.ikunshare.com/url') &&
              u.contains('source=wy') &&
              u.contains('songId=1851244158') &&
              u.contains('quality=master'),
        ),
        isTrue,
      );
    });

    test('ikun checkUpdate uses bare lx and delivers updateAlert', () async {
      // checkUpdate is pumped after load; give it a moment.
      for (var i = 0; i < 20; i++) {
        if (engine.lastUpdateAlert('ikun') != null) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final alert = engine.lastUpdateAlert('ikun');
      expect(alert, isNotNull);
      expect(alert!['log'], 'v23 available');
    });

    test('suyin wy musicUrl end to end', () async {
      final song = Song(
        songId: '1851244158',
        title: 'Test',
        platform: MusicPlatform.wy,
      );
      final url = await engine.getMusicUrl(
        scriptId: 'suyin',
        platform: 'wy',
        song: song,
        quality: AudioQuality.q320k,
      );
      expect(url, 'https://cdn.example.com/wy.mp3');
    });

    test('suyin kw search end to end', () async {
      final results = await engine.search(
        scriptId: 'suyin',
        platform: 'kw',
        keyword: 'Test',
        limit: 5,
      );
      expect(results, isNotEmpty);
      expect(results.first['name'], 'Test Song');
      final song = LxScriptEngine.lxSongFromJson(
        results.first,
        MusicPlatform.kw,
      );
      expect(song, isNotNull);
      expect(song!.songId, '12345');
      expect(song.title, 'Test Song');
      expect(song.artist, 'Singer');
      expect(song.dur, 185);
    });

    test('suyin QQ musicUrl is null without a key (key sanitised)', () async {
      final song = Song(
        songId: '0039MnYb0qxYhV',
        title: 'Test',
        platform: MusicPlatform.tx,
      );
      final url = await engine.getMusicUrl(
        scriptId: 'suyin',
        platform: 'tx',
        song: song,
        quality: AudioQuality.master,
      );
      expect(url, isNull);
      // And the script never called the QQ API without a key.
      expect(log.any((u) => u.contains('oiapi.net/api/QQ_Music')), isFalse);
    });

    test('unknown action throws a readable script error', () async {
      await expectLater(
        engine.requestAction(
          scriptId: 'ikun',
          action: 'bogus',
          source: 'wy',
          info: const {},
        ),
        throwsA(
          isA<LxScriptException>().having(
            (e) => e.message,
            'message',
            contains('action not support'),
          ),
        ),
      );
    });
  }, skip: _linuxSkip);

  group('custom scripts', () {
    test('valid script URL loads and registers sources', () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScript(
        'https://example.com/custom.js',
      );
      expect(info.loaded, isTrue);
      expect(info.name, 'TestScript');
      expect(info.isCustom, isTrue);
      expect(info.sources.map((s) => s.platform), ['wy']);
      expect(info.configView, isNotNull);
      expect(info.configView!['title'], 'Cfg');
      final url = await engine.getMusicUrl(
        scriptId: info.id,
        platform: 'wy',
        song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
        quality: AudioQuality.q320k,
      );
      expect(url, 'https://example.com/x.mp3');
    });

    test('bad script URL fails and is not saved', () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine.addCustomScript('https://example.com/bad.js'),
        throwsA(isA<LxScriptException>()),
      );
      expect(engine.scripts.where((s) => s.isCustom), isEmpty);
    });

    test('script reporting a non-master tier at master is hires (P1-L1)',
        () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScript(
        'https://example.com/map.js',
      );
      expect(info.loaded, isTrue);
      final r = await engine.getMusicUrlWithTier(
        scriptId: info.id,
        platform: 'wy',
        song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
        quality: AudioQuality.master,
      );
      expect(r, isNotNull);
      expect(r!.url, 'https://example.com/m.flac');
      // The script said flac: hires, never master.
      expect(r.actualQuality, AudioQuality.hires);
      // The plain-URL form still returns the URL itself.
      expect(
        await engine.getMusicUrl(
          scriptId: info.id,
          platform: 'wy',
          song: Song(songId: '1', title: 'x', platform: MusicPlatform.wy),
          quality: AudioQuality.master,
        ),
        'https://example.com/m.flac',
      );
    });

    test('non-http URL is rejected', () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine.addCustomScript('ftp://example.com/x.js'),
        throwsA(isA<LxScriptException>()),
      );
    });
  }, skip: _linuxSkip);

  // Deferred `inited` (tongyi UAF fix). Uses the fake runtime, so it
  // runs on the Linux host too — no native JS lib needed.
  group('deferred inited', () {
    test('script sending inited after 150ms still loads', () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
        runtimeFactory: () => _FakeJsRuntime(
          initedDelay: const Duration(milliseconds: 150),
        ),
      );
      addTearDown(engine.dispose);
      final info = await engine.addCustomScript(
        'https://example.com/deferred.js',
      );
      expect(info.loaded, isTrue);
      expect(info.name, 'DeferredScript');
      expect(info.sources.map((s) => s.platform), ['wy']);
      expect(info.sourceFor('wy')!.actions, ['musicUrl']);
    });

    test('script never sending inited still fails (bounded wait)', () async {
      final log = <String>[];
      final engine = LxScriptEngine(
        dio: buildFakeDio(respond: _respond, log: log),
        runtimeFactory: () => _FakeJsRuntime(initedDelay: null),
        // Default inited wait is 10s (slow scripts); inject 1s here
        // so this failure case stays fast.
        initedTimeout: const Duration(seconds: 1),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine.addCustomScript('https://example.com/never.js'),
        throwsA(isA<LxScriptException>()),
      );
      expect(engine.scripts.where((s) => s.isCustom), isEmpty);
    });
  });

  // P1-L1 tier check on a script-reported tier string — pure logic,
  // runs on the Linux host too (no JS runtime needed).
  group('reportedTierFor', () {
    test('master request: only a literal master report keeps master',
        () {
      expect(
        LxScriptEngine.reportedTierFor(
          reported: 'master',
          requested: AudioQuality.master,
        ),
        AudioQuality.master,
      );
      expect(
        LxScriptEngine.reportedTierFor(
          reported: 'flac',
          requested: AudioQuality.master,
        ),
        AudioQuality.hires,
      );
      expect(
        LxScriptEngine.reportedTierFor(
          reported: '320k',
          requested: AudioQuality.master,
        ),
        AudioQuality.hires,
      );
      expect(
        LxScriptEngine.reportedTierFor(
          reported: null,
          requested: AudioQuality.master,
        ),
        isNull,
      );
    });

    test('non-master requests keep the declared label', () {
      expect(
        LxScriptEngine.reportedTierFor(
          reported: 'flac',
          requested: AudioQuality.hires,
        ),
        isNull,
      );
      expect(
        LxScriptEngine.reportedTierFor(
          reported: 'master',
          requested: AudioQuality.hires,
        ),
        isNull,
      );
    });
  });

  // File upload (chen 2026-11-18): import from picked .js contents.
  // Fake runtime, so it runs on the Linux host too. getMusicUrl is
  // NOT asserted here — the fake runtime cannot answer dispatches
  // (the URL-path group covers it end to end on iOS with the real
  // runtime); the file path shares _loadScript with the URL path.
  group('custom scripts from file', () {
    LxScriptEngine fileEngine() => LxScriptEngine(
          runtimeFactory: () => _FakeJsRuntime(
            initedDelay: const Duration(milliseconds: 150),
          ),
        );

    test('valid file script imports and registers sources', () async {
      final engine = fileEngine();
      addTearDown(engine.dispose);
      final info = await engine.addCustomScriptFromFile(
        fileName: 'my-source.js',
        code: _tinyScript,
      );
      expect(info.loaded, isTrue);
      expect(info.name, 'TestScript');
      expect(info.isCustom, isTrue);
      expect(info.id, startsWith('custom:file:'));
      expect(info.origin, 'file://my-source.js');
      expect(info.sources.map((s) => s.platform), ['wy']);
      expect(info.sourceFor('wy')!.actions, ['musicUrl']);
      expect(engine.script(info.id), isNotNull);
    });

    test('script without globalThis.lx throws and is not registered',
        () async {
      final engine = fileEngine();
      addTearDown(engine.dispose);
      await expectLater(
        engine.addCustomScriptFromFile(
          fileName: 'bad.js',
          code: 'console.log("hello");',
        ),
        throwsA(isA<LxScriptException>()),
      );
      expect(engine.scripts.where((s) => s.isCustom), isEmpty);
    });

    test('same file twice does not duplicate', () async {
      final engine = fileEngine();
      addTearDown(engine.dispose);
      final first = await engine.addCustomScriptFromFile(
        fileName: 'my-source.js',
        code: _tinyScript,
      );
      final second = await engine.addCustomScriptFromFile(
        fileName: 'my-source.js',
        code: _tinyScript,
      );
      expect(second.id, first.id);
      expect(engine.scripts.where((s) => s.isCustom).length, 1);
    });

    test('name falls back to the file name without @name', () async {
      final engine = fileEngine();
      addTearDown(engine.dispose);
      final info = await engine.addCustomScriptFromFile(
        fileName: 'cool-source.js',
        code: _noNameScript,
      );
      expect(info.name, 'cool-source');
      expect(info.origin, 'file://cool-source.js');
    });
  });
}

/// Script without an `@name` header (name must fall back to the file
/// name). The fake runtime delivers `inited` for any non-prelude
/// evaluate, so the body only needs `globalThis.lx`.
const String _noNameScript = '''
// @version 1.0.0
const { EVENT_NAMES, send } = globalThis.lx;
send(EVENT_NAMES.inited, { status: true, sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] } } });
''';
