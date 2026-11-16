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
// - all 4 scripts load and send `inited` with exactly the capabilities
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
  if (url == 'https://example.com/bad.js') {
    return {'status': 200, 'body': 'this is not js {{{'};
  }
  return {'status': 404, 'body': '{}'};
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

    test('all six load with exactly their declared capabilities', () {
      expect(engine.scripts.length, 6);
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
      // engine correctly excludes it at the master tier (actual
      // result {ikun, luoxue}); only scripts listing 'master' get a
      // master job. Never substitute hires for master.
      expect(
        masterJobs.map((j) => j.key).toSet(),
        {'lx:ikun', 'lx:luoxue'},
      );
      final hiresJobs = engine.scriptJobsFor(
        MusicPlatform.wy,
        AudioQuality.hires,
        song,
      );
      expect(
        hiresJobs.map((j) => j.key).toSet(),
        {'lx:ikun', 'lx:suyin', 'lx:luoxue', 'lx:fish', 'lx:jiexiang'},
      );
      final q320Jobs = engine.scriptJobsFor(
        MusicPlatform.wy,
        AudioQuality.q320k,
        song,
      );
      expect(
        q320Jobs.map((j) => j.key).toSet(),
        {
          'lx:ikun',
          'lx:xinlan',
          'lx:suyin',
          'lx:luoxue',
          'lx:fish',
          'lx:jiexiang',
        },
      );
      // 溯音 is the only script declaring search (kw/mg).
      expect(
        engine.searchLegsFor(MusicPlatform.kw).map((l) => l.scriptId),
        ['suyin'],
      );
      expect(engine.searchLegsFor(MusicPlatform.wy), isEmpty);
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
}
