// LX Music script engine (M-P0-6) — runs 歌一刀 / LX Music-format
// custom-source scripts (the 6 bundled in assets/lx_scripts/ + user-added
// URLs) and exposes them as music resolver sources.
//
// How it works:
// - ONE JS runtime per script (flutter_js; JavaScriptCore on iOS,
//   QuickJS elsewhere). Separate runtimes because every script declares
//   top-level `const API_URL` etc. — sharing one global scope would throw
//   on redeclaration.
// - Before each script, [kLxPrelude] injects `globalThis.lx` per LX Music
//   conventions: EVENT_NAMES / request / on / send / utils / env /
//   version, plus a bare `lx` alias (ikun/落雪 call `lx.EVENT_NAMES`).
// - `lx.request(url, options, callback)` is bridged to Dart Dio: JS
//   posts the job on the LxRequest channel, Dart performs the HTTP call
//   and delivers the result back with `__haoLxDeliver`.
// - `lx.send` events (inited / updateAlert / showConfigView) arrive on
//   the LxSend channel. `inited` carries the script's source map —
//   that is the ONLY capability record: a script is registered with
//   exactly the actions/qualities it declares (musicUrl / search /
//   pic / lyric), never more.
// - Dart → JS calls go through `__haoLxDispatch(event, payloadJson)`;
//   the result (or error string) is stashed in JS and polled by Dart
//   while `executePendingJob()` pumps the promise queue.
// - Console output is captured per script (last 100 lines, `logs`),
//   never printed to stdout.
//
// Scripts as files: the 20 files in assets/lx_scripts/ are copies of
// research/kmusic/*.js (ikun/新澜/溯音/落雪) plus the pdone
// lx-music-source fish (v1.9.0) and 杰翔聚合音源 (v2.3.0) scripts,
// plus 14 scripts from chen's V261115 pack (2026-11-17, each verified
// live via the Node LX harness: real prelude + real HTTP, wy 320k
// returning a curl-verified MP3; 回避聚合 + stellarwave-v0.0.14 had
// embedded shared keys/tokens, sanitised to '' before packaging and
// re-verified still working),
// and are ONLY the first-install seed. On first launch each is copied
// ([LxScriptFileStore]) and the engine loads from there — never from
// assets directly — so a deleted bundled script stays deleted (the
// file is removed and the id is recorded in the Hive deleted set; the
// seed never re-creates it). The 溯音 script's embedded shared oiapi
// key was sanitised to '' before packaging — no key/secret ships in
// the app. The fifth script from the notes (非常刀) is NOT in
// research/kmusic/ (only 4 .js files exist there), so it is not bundled.
// Script update checks (checkUpdate) are allowed to run — they are
// fire-and-forget, never block loading, and a failed check is silent.
//
// iOS notes: the engine uses plain Dio, so script traffic follows the
// app's ATS rules. Info.plist currently sets NO ATS exception, which
// means cleartext http:// script hosts (ikun's api.ikunshare.com,
// 落雪's http://220.167.101.253:6001) will be blocked on iOS until an
// ATS exception is added or those hosts move to https. The https
// scripts (新澜, zddyr-backed paths) are unaffected.
// Promise pumping on iOS (JavaScriptCore) relies on flutter_js's
// polling pattern — verified on the VM's QuickJS only; chen's phone
// test must confirm script playback on iOS.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';

import '../../core/network/http_client.dart';
import 'lx_script_files.dart';
import 'lx_script_store.dart';
import 'music_models.dart';
import 'music_quality.dart';

/// JS prelude injected into every script runtime before the script
/// itself. Pure JS, no host dependencies beyond `sendMessage` (provided
/// by flutter_js) — no atob/btoa/TextEncoder (QuickJS lacks them), so
/// base64/UTF-8 are implemented inline.
const String kLxPrelude = r'''
(function () {
  if (globalThis.__haoLxInstalled) return;
  var __haoLog = function (level, args) {
    try {
      var parts = [];
      for (var i = 0; i < args.length; i++) {
        var a = args[i];
        try { parts.push(typeof a === 'string' ? a : JSON.stringify(a)); }
        catch (e) { parts.push(String(a)); }
      }
      sendMessage('LxLog', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, level: level, text: parts.join(' ') }));
    } catch (e) {}
  };
  if (typeof console === 'undefined') { globalThis.console = {}; }
  console.log = function () { __haoLog('log', arguments); };
  console.info = function () { __haoLog('info', arguments); };
  console.warn = function () { __haoLog('warn', arguments); };
  console.error = function () { __haoLog('error', arguments); };
  console.debug = function () { __haoLog('debug', arguments); };
  console.group = function () { __haoLog('group', arguments); };
  console.groupEnd = function () { __haoLog('groupEnd', arguments); };

  var __handlers = {};
  var __reqSeq = 0;
  var __reqCallbacks = {};
  var __dispatchSeq = 0;
  var __dispatchResults = {};

  function __on(event, fn) {
    if (!__handlers[event]) __handlers[event] = [];
    __handlers[event].push(fn);
  }
  function __send(event, data) {
    try { sendMessage('LxSend', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, event: event, data: data === undefined ? null : data })); } catch (e) {}
  }
  function __request(url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    options = options || {};
    var id = ++__reqSeq;
    __reqCallbacks[id] = callback;
    var body = (options.body !== undefined && options.body !== null) ? options.body : null;
    if (body !== null && typeof body !== 'string') {
      try { body = JSON.stringify(body); } catch (e) { body = String(body); }
    }
    try {
      sendMessage('LxRequest', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, id: id, url: String(url), method: options.method || 'GET', headers: options.headers || {}, body: body, timeout: options.timeout || 0 }));
    } catch (e) {
      var cb = __reqCallbacks[id];
      delete __reqCallbacks[id];
      if (cb) { try { cb(new Error(String(e)), null); } catch (e2) {} }
    }
  }
  globalThis.__haoLxDeliver = function (id, errText, respJson) {
    var cb = __reqCallbacks[id];
    if (!cb) return 'no-callback';
    delete __reqCallbacks[id];
    var resp = null;
    if (respJson) { try { resp = JSON.parse(respJson); } catch (e) { resp = null; } }
    try {
      if (errText) cb(new Error(errText), null);
      else cb(null, resp);
    } catch (e) {}
    return 'ok';
  };
  globalThis.__haoLxDispatch = function (event, payloadJson) {
    var id = ++__dispatchSeq;
    __dispatchResults[id] = { done: false, ok: false, value: null, error: null };
    var payload = null;
    try { payload = JSON.parse(payloadJson); }
    catch (e) { __dispatchResults[id] = { done: true, ok: false, value: null, error: 'bad payload: ' + e.message }; return id; }
    var handlers = __handlers[event] || [];
    if (handlers.length === 0) { __dispatchResults[id] = { done: true, ok: false, value: null, error: 'no handler for event ' + event }; return id; }
    try {
      var ret = handlers[0](payload);
      if (ret && typeof ret.then === 'function') {
        ret.then(
          function (v) { __dispatchResults[id] = { done: true, ok: true, value: v === undefined ? null : v, error: null }; },
          function (e) { __dispatchResults[id] = { done: true, ok: false, value: null, error: e && e.message ? e.message : String(e) }; }
        );
      } else {
        __dispatchResults[id] = { done: true, ok: true, value: ret === undefined ? null : ret, error: null };
      }
    } catch (e) {
      __dispatchResults[id] = { done: true, ok: false, value: null, error: e && e.message ? e.message : String(e) };
    }
    return id;
  };
  globalThis.__haoLxDispatchResult = function (id) {
    var r = __dispatchResults[id];
    if (!r) return JSON.stringify({ done: true, ok: false, value: null, error: 'unknown dispatch ' + id });
    var out = JSON.stringify(r);
    if (r.done) delete __dispatchResults[id];
    return out;
  };
  // Timers: flutter_js's native setTimeout is bridged through a
  // process-wide static Dart callback (JSCore: _sendMessageDartFunc),
  // so with 20 runtimes a timer scheduled by script A fires its
  // callback in the NEWEST runtime's context — and after A is
  // disposed, in a released JSContext (native UAF, v1.0.7-class).
  // Route timers through our own stamped channel instead: Dart
  // fires __haoLxFireTimeout only on the runtime still registered
  // under this script id, and drops the timer outright once the
  // script is removed. flutter_js's own extensions (fetch /
  // handle_promises) do not use setTimeout, so nothing else loses
  // its timer by overwriting the global here.
  var __haoTimeoutSeq = 0;
  var __haoTimeoutCallbacks = {};
  globalThis.__haoLxFireTimeout = function (idx) {
    var fn = __haoTimeoutCallbacks[idx];
    if (!fn) return 'no-timer';
    delete __haoTimeoutCallbacks[idx];
    try { fn(); } catch (e) {}
    return 'ok';
  };
  globalThis.setTimeout = function (fn, ms) {
    if (typeof fn === 'string') { try { fn = new Function(fn); } catch (e) { return 0; } }
    if (typeof fn !== 'function') return 0;
    var args = [];
    for (var i = 2; i < arguments.length; i++) args.push(arguments[i]);
    var id = ++__haoTimeoutSeq;
    __haoTimeoutCallbacks[id] = function () { fn.apply(null, args); };
    try { sendMessage('LxTimeout', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, action: 'set', timeoutIndex: String(id), timeout: ms || 0 })); } catch (e) {}
    return id;
  };
  globalThis.clearTimeout = function (id) {
    delete __haoTimeoutCallbacks[id];
    try { sendMessage('LxTimeout', JSON.stringify({ scriptId: globalThis.__haoLxScriptId || null, action: 'clear', timeoutIndex: String(id), timeout: 0 })); } catch (e) {}
  };
  var __b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function __b64encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += __b64chars[b0 >> 2] + __b64chars[((b0 & 3) << 4) | (b1 >> 4)];
      out += i + 1 < bytes.length ? __b64chars[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += i + 2 < bytes.length ? __b64chars[b2 & 63] : '=';
    }
    return out;
  }
  function __b64decode(s) {
    s = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
    var bytes = [];
    var buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (c === '=') break;
      var v = __b64chars.indexOf(c);
      if (v < 0) continue;
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; bytes.push((buf >> bits) & 255); }
    }
    return bytes;
  }
  function __utf8Encode(str) {
    var utf8 = unescape(encodeURIComponent(str));
    var bytes = [];
    for (var i = 0; i < utf8.length; i++) bytes.push(utf8.charCodeAt(i) & 255);
    return bytes;
  }
  function __utf8Decode(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
  }
  function __bufFrom(data, encoding) {
    encoding = encoding || 'utf-8';
    var bytes;
    if (encoding === 'base64') bytes = __b64decode(data);
    else if (encoding === 'hex') {
      var h = String(data); bytes = [];
      for (var i = 0; i + 1 < h.length; i += 2) bytes.push(parseInt(h.substring(i, i + 2), 16));
    } else bytes = __utf8Encode(String(data));
    return { __haoBuf: true, bytes: bytes };
  }
  function __bufToString(buf, encoding) {
    encoding = encoding || 'utf-8';
    var bytes = (buf && buf.bytes) ? buf.bytes : [];
    if (encoding === 'base64') return __b64encode(bytes);
    if (encoding === 'hex') {
      var s = '';
      for (var i = 0; i < bytes.length; i++) { var x = bytes[i].toString(16); s += x.length === 1 ? '0' + x : x; }
      return s;
    }
    return __utf8Decode(bytes);
  }
  globalThis.lx = {
    EVENT_NAMES: { inited: 'inited', request: 'request', updateAlert: 'updateAlert', showConfigView: 'showConfigView' },
    request: __request,
    on: __on,
    send: __send,
    utils: { buffer: { from: __bufFrom, bufToString: __bufToString } },
    env: 'mobile',
    version: '1.0.4'
  };
  globalThis.__haoLxInstalled = true;
})();
var lx = globalThis.lx;
''';

class LxScriptException implements Exception {
  LxScriptException(this.message);
  final String message;
  @override
  String toString() => 'LxScriptException: $message';
}

/// Injectable JS runtime factory (production: flutter_js).
typedef LxRuntimeFactory = JavascriptRuntime Function();

/// Injectable asset loader (production: rootBundle).
typedef LxAssetLoader = Future<String> Function(String assetPath);

/// One bundled script. The blurb is static display text verified
/// against the script source; live capabilities come from the script's
/// own `inited` event, never from this list.
class LxBundledScript {
  const LxBundledScript({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.blurb,
  });
  final String id;
  final String name;
  final String assetPath;
  final String blurb;
}

const List<LxBundledScript> kBundledLxScripts = [
  LxBundledScript(
    id: 'ikun',
    name: 'ikun音源',
    assetPath: 'assets/lx_scripts/ikun.js',
    blurb: 'ikun音源[公益版] · 网易云 / 酷我 · 仅播放链接',
  ),
  LxBundledScript(
    id: 'xinlan',
    name: '新澜音源',
    assetPath: 'assets/lx_scripts/xinlan.js',
    blurb: '新澜音源(公益版) · 全平台 320k · 仅播放链接',
  ),
  LxBundledScript(
    id: 'suyin',
    name: '溯音音源',
    assetPath: 'assets/lx_scripts/suyin.js',
    blurb: '溯音音源 · QQ / 网易 / 酷我 / 咪咕 · 播放链接 + 酷我/咪咕搜索',
  ),
  LxBundledScript(
    id: 'luoxue',
    name: '落雪',
    assetPath: 'assets/lx_scripts/luoxue.js',
    blurb: '落雪 · QQ / 网易 · 仅播放链接',
  ),
  LxBundledScript(
    id: 'jiexiang',
    name: '杰翔聚合音源',
    assetPath: 'assets/lx_scripts/jiexiang.js',
    blurb: '杰翔聚合音源 · QQ / 网易 / 酷我 / 酷狗 / 咪咕 · 仅播放链接，酷狗支持 Master',
  ),
  LxBundledScript(
    id: 'fish',
    name: 'fish音源',
    assetPath: 'assets/lx_scripts/fish.js',
    blurb: 'fish音源 · QQ / 网易 / 酷我 / 酷狗 / 咪咕 · 仅播放链接',
  ),
  LxBundledScript(
    id: 'hyw',
    name: 'HYWmusic音源',
    assetPath: 'assets/lx_scripts/hyw.js',
    blurb: 'HYWmusic 公益版 · 网易 / QQ / 酷我 / 酷狗 / 咪咕 / 千千 / 哔哩 / 油管 / 虾米 · 仅播放链接',
  ),
  LxBundledScript(
    id: 'helloworld',
    name: 'HelloWorld音源',
    assetPath: 'assets/lx_scripts/helloworld.js',
    blurb: 'HelloWorld音源 · 全平台 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'aya',
    name: 'aya音源',
    assetPath: 'assets/lx_scripts/aya.js',
    blurb: 'aya音源 · 网易 / 酷我 / 酷狗 / 咪咕 · 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'gdstudio',
    name: 'gdstudio音乐源',
    assetPath: 'assets/lx_scripts/gdstudio.js',
    blurb: 'gdstudio音乐源 · 全平台 320k / 无损 · 仅播放链接',
  ),
  LxBundledScript(
    id: 'yuningxi',
    name: '玉宁熙音源',
    assetPath: 'assets/lx_scripts/yuningxi.js',
    blurb: '玉宁熙音源 · 全平台 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'stellarwave',
    name: 'stellarwave音源',
    assetPath: 'assets/lx_scripts/stellarwave.js',
    blurb: 'stellarwave v4.0.2 · 全平台 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'stellarwave014',
    name: 'stellarwave v0.0.14',
    assetPath: 'assets/lx_scripts/stellarwave014.js',
    blurb: 'stellarwave v0.0.14 · 全平台 320k / 无损 · 仅播放链接（内置密钥已清空）',
  ),
  LxBundledScript(
    id: 'xinghai',
    name: '星海音源',
    assetPath: 'assets/lx_scripts/xinghai.js',
    blurb: '星海音源 v2.3.19 · 全平台 320k / 无损 / Master · 播放链接 + 歌词 / 封面',
  ),
  LxBundledScript(
    id: 'huibi',
    name: '回避聚合音源',
    assetPath: 'assets/lx_scripts/huibi.js',
    blurb: '回避聚合音源 · 全平台 320k / 无损 / Master · 仅播放链接（内置密钥已清空）',
  ),
  LxBundledScript(
    id: 'molan',
    name: '墨澜音乐源',
    assetPath: 'assets/lx_scripts/molan.js',
    blurb: '墨澜音乐源 v2.3.8 · 全平台 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'yuxi',
    name: '屿溪音源',
    assetPath: 'assets/lx_scripts/yuxi.js',
    blurb: '屿溪音源 · 网易 / QQ / 酷狗 / 酷我 · 320k / 无损 / Master · 仅播放链接',
  ),
  LxBundledScript(
    id: 'kuliao',
    name: '裤佬SVIP音源',
    assetPath: 'assets/lx_scripts/kuliao.js',
    blurb: '裤佬SVIP音源 · 全平台 320k / 无损 / Master · 播放链接 + 搜索',
  ),
  LxBundledScript(
    id: 'feichangdao',
    name: '非常刀音源',
    assetPath: 'assets/lx_scripts/feichangdao.js',
    blurb: '非常刀 v5 · 全平台 320k / 无损 · 播放链接 + 搜索',
  ),
  LxBundledScript(
    id: 'tongyi',
    name: '统一音乐源',
    assetPath: 'assets/lx_scripts/tongyi.js',
    blurb: '统一音乐源 · 酷我 / 网易 · 仅播放链接',
  ),
];

/// One platform entry declared by one script's `inited` event.
/// This is the script's OWN capability claim — the engine never adds
/// actions or qualities the script did not declare.
class LxScriptSourceInfo {
  const LxScriptSourceInfo({
    required this.scriptId,
    required this.scriptName,
    required this.platform,
    required this.displayName,
    required this.actions,
    required this.qualities,
  });

  final String scriptId;
  final String scriptName;

  /// LX platform code ('wy' | 'tx' | 'kg' | 'kw' | 'mg' | 'git' …).
  final String platform;
  final String displayName;

  /// Subset of musicUrl / search / pic / lyric, as declared.
  final List<String> actions;

  /// Quality strings as declared (e.g. ['128k','320k','flac','hires',
  /// 'master']); 'flac24bit' / 'atmos' may appear too.
  final List<String> qualities;

  bool get supportsMusicUrl => actions.contains('musicUrl');
  bool get supportsSearch => actions.contains('search');
}

/// A loaded (or failed) script with its declared sources.
class LxScriptInfo {
  LxScriptInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.origin,
    required this.isCustom,
    required this.loaded,
    this.error,
    List<LxScriptSourceInfo>? sources,
    this.configView,
    this.updateAlert,
  }) : sources = sources ?? const [];

  factory LxScriptInfo.failed({
    required String id,
    required String name,
    required String origin,
    required String error,
  }) =>
      LxScriptInfo(
        id: id,
        name: name,
        version: '',
        origin: origin,
        isCustom: id.startsWith('custom:'),
        loaded: false,
        error: error,
      );

  final String id;
  final String name;
  final String version;

  /// Asset path for bundled scripts, URL for custom ones.
  final String origin;
  final bool isCustom;
  final bool loaded;
  final String? error;
  final List<LxScriptSourceInfo> sources;

  /// Last showConfigView payload the script sent, if any. The config
  /// UI is not built yet — recorded here for a later settings screen.
  final Map<String, dynamic>? configView;

  /// Last updateAlert payload the script sent, if any.
  final Map<String, dynamic>? updateAlert;

  LxScriptSourceInfo? sourceFor(String platform) {
    for (final s in sources) {
      if (s.platform == platform) return s;
    }
    return null;
  }
}

/// One script's JS runtime + its Dart-side channels.
///
/// Routing (flutter_js 0.8.7 static-callback cross-talk, JSCore):
/// `JavascriptCoreRuntime._sendMessageDartFunc` is a static field
/// overwritten by every new runtime's constructor, so on iOS ALL
/// runtimes' `sendMessage` calls land in the NEWEST runtime's Dart
/// handlers. (QuickJS2 builds a per-instance closure instead, so
/// Android is unaffected — but the routing below is harmless there.)
/// Every message our prelude sends is therefore stamped with
/// `scriptId` (`globalThis.__haoLxScriptId`, set by [_loadScript]
/// right after the prelude), and each handler below forwards a
/// stamped message to the runtime still registered under that id —
/// or drops it when that script was removed. Unstamped messages
/// (legacy / foreign) fall back to this runtime, as before.
/// Dispose unregisters the id, so a message arriving after removal
/// can never touch a released JSContext.
class _ScriptRuntime {
  _ScriptRuntime(this.js, this.scriptId) {
    _byScriptId[scriptId] = this;
    js.onMessage('LxSend', (args) {
      if (args is Map) {
        _route(Map<String, dynamic>.from(args))?._ingestSend(args);
      }
    });
    js.onMessage('LxRequest', (args) {
      if (args is Map) {
        _route(Map<String, dynamic>.from(args))?._ingestRequest(args);
      }
    });
    js.onMessage('LxLog', (args) {
      if (args is Map) {
        _route(Map<String, dynamic>.from(args))?._ingestLog(args);
      }
    });
    js.onMessage('LxTimeout', (args) {
      if (args is Map) {
        _route(Map<String, dynamic>.from(args))?._ingestTimeout(args);
      }
    });
  }

  /// Live runtimes by script id. The single source of truth for
  /// "which runtime owns this message / is this timer still alive":
  /// dispose removes the entry, so anything stamped for a removed
  /// script is dropped instead of delivered to a released context.
  static final Map<String, _ScriptRuntime> _byScriptId = {};

  /// Resolve the owning runtime for a stamped message. Returns this
  /// runtime for unstamped messages; returns null when the stamped
  /// script is gone (caller must drop the message, never fall back
  /// to the newest runtime — that is exactly the cross-talk).
  _ScriptRuntime? _route(Map<String, dynamic> m) {
    final stamped = m['scriptId']?.toString();
    if (stamped == null || stamped.isEmpty) return this;
    return _byScriptId[stamped];
  }

  final JavascriptRuntime js;
  final String scriptId;
  final List<_HttpJob> httpJobs = [];

  /// Last 100 console lines from this script.
  final List<String> logs = [];

  bool initedReceived = false;
  Map<String, dynamic>? initedData;
  Map<String, dynamic>? lastUpdateAlert;
  Map<String, dynamic>? configView;

  bool _disposed = false;

  /// Pending prelude-setTimeout timers, by JS timeout index.
  /// Cancelled on dispose, so a timer can never fire into a
  /// released JSContext (P1-2 slow-inited case).
  final Map<String, Timer> _timers = {};

  void _ingestSend(Map args) {
    if (_disposed) return;
    final m = Map<String, dynamic>.from(args);
    final event = m['event']?.toString();
    final data = m['data'];
    if (event == 'inited') {
      initedReceived = true;
      initedData = data is Map ? Map<String, dynamic>.from(data) : null;
    } else if (event == 'updateAlert') {
      lastUpdateAlert = data is Map ? Map<String, dynamic>.from(data) : null;
    } else if (event == 'showConfigView') {
      configView = data is Map ? Map<String, dynamic>.from(data) : null;
    }
  }

  void _ingestRequest(Map args) {
    if (_disposed) return;
    try {
      httpJobs.add(_HttpJob.fromJson(Map<String, dynamic>.from(args)));
    } catch (_) {}
  }

  void _ingestLog(Map args) {
    if (_disposed) return;
    final text = args['text']?.toString() ?? '';
    if (text.isNotEmpty) {
      logs.add(text);
      if (logs.length > 100) logs.removeAt(0);
    }
  }

  void _ingestTimeout(Map args) {
    if (_disposed) return;
    final m = Map<String, dynamic>.from(args);
    final idx = m['timeoutIndex']?.toString() ?? '';
    if (idx.isEmpty) return;
    if (m['action'] == 'clear') {
      _timers.remove(idx)?.cancel();
      return;
    }
    _timers.remove(idx)?.cancel();
    final ms = (m['timeout'] as num?)?.toInt() ?? 0;
    _timers[idx] = Timer(Duration(milliseconds: ms < 0 ? 0 : ms), () {
      _timers.remove(idx);
      _fireTimeout(idx);
    });
  }

  /// Fire one prelude timer on THIS runtime — only when this runtime
  /// is still the registered owner of its script id. The registry
  /// check is the dispose linkage: after removeScript/dispose the
  /// entry is gone and the timer is dropped, never evaluated.
  void _fireTimeout(String idx) {
    if (_disposed || !identical(_byScriptId[scriptId], this)) return;
    try {
      js.evaluate("__haoLxFireTimeout('$idx')");
    } catch (_) {}
    try {
      js.executePendingJob();
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    // Only unregister when this instance is still the owner: a
    // re-load registers its replacement first, and disposing the old
    // instance must not unregister the new one.
    if (identical(_byScriptId[scriptId], this)) {
      _byScriptId.remove(scriptId);
    }
    try {
      js.dispose();
    } catch (_) {}
  }
}

class _HttpJob {
  _HttpJob({
    required this.id,
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
    required this.timeoutMs,
  });

  factory _HttpJob.fromJson(Map<String, dynamic> j) => _HttpJob(
        id: (j['id'] as num?)?.toInt() ?? 0,
        url: j['url']?.toString() ?? '',
        method: j['method']?.toString() ?? 'GET',
        headers: j['headers'] is Map
            ? {
                for (final e in (j['headers'] as Map).entries)
                  e.key.toString(): e.value.toString(),
              }
            : <String, String>{},
        body: j['body']?.toString(),
        timeoutMs: (j['timeout'] as num?)?.toInt() ?? 0,
      );

  final int id;
  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final int timeoutMs;
}

/// LX script engine — process-wide singleton in production
/// ([instance]); tests construct their own with injected Dio /
/// runtime factory / asset loader.
class LxScriptEngine {
  LxScriptEngine({
    Dio? dio,
    LxRuntimeFactory? runtimeFactory,
    LxAssetLoader? assetLoader,
    this._fileStore,
    this.initedTimeout = const Duration(seconds: 10),
  })  : _dio = dio ?? sharedDio(),
        _runtimeFactory =
            runtimeFactory ?? (() => getJavascriptRuntime(xhr: false)),
        _assetLoader =
            assetLoader ?? ((path) => rootBundle.loadString(path));

  static final LxScriptEngine instance =
      LxScriptEngine(fileStore: LxScriptFileStore());

  final Dio _dio;
  final LxRuntimeFactory _runtimeFactory;
  final LxAssetLoader _assetLoader;

  /// File-backed bundled scripts (production). Null in tests that
  /// construct the engine without one — those load bundled scripts
  /// from assets exactly as before.
  final LxScriptFileStore? _fileStore;

  /// How long [_loadScript] waits for a script's deferred `inited`
  /// (polled every 100ms, early exit on arrival). 10s covers scripts
  /// that defer `inited` behind a slow update check (原版念心 waits
  /// 4–5s); a script that never sends `inited` still fails, bounded.
  /// Tests inject a shorter value so the never-inited case stays fast.
  final Duration initedTimeout;

  Future<void>? _initFuture;
  final Map<String, _ScriptRuntime> _runtimes = {};
  final Map<String, LxScriptInfo> _scripts = {};
  bool _disposed = false;

  List<LxScriptInfo> get scripts => List.unmodifiable(_scripts.values);

  List<LxScriptSourceInfo> get allSources =>
      [for (final s in _scripts.values) ...s.sources];

  LxScriptInfo? script(String id) => _scripts[id];

  /// Idempotent: loads bundled scripts (each in its own runtime) and
  /// then persisted custom scripts. Safe to call repeatedly; later
  /// callers await the same future. Never throws — per-script failures
  /// are recorded on the script info.
  Future<void> ensureInitialized() {
    _initFuture ??= _init();
    return _initFuture!;
  }

  Future<void> _init() async {
    for (final spec in kBundledLxScripts) {
      // Deleted bundled scripts are gone: never re-seeded, never
      // loaded — including after an app restart.
      if (LxScriptSourcesStore.isBundledDeleted(spec.id)) continue;
      String? code;
      final fs = _fileStore;
      if (fs != null) {
        try {
          await fs.seedIfMissing(
            id: spec.id,
            assetPath: spec.assetPath,
            assetLoader: _assetLoader,
          );
          code = await fs.read(spec.id);
        } catch (_) {
          code = null;
        }
      }
      try {
        code ??= await _assetLoader(spec.assetPath);
        await _loadScript(
          id: spec.id,
          name: spec.name,
          code: code,
          origin: spec.assetPath,
          isCustom: false,
        );
      } catch (e) {
        _scripts[spec.id] = LxScriptInfo.failed(
          id: spec.id,
          name: spec.name,
          origin: spec.assetPath,
          error: e.toString(),
        );
      }
    }
    for (final saved in LxScriptSourcesStore.customScripts()) {
      try {
        await _loadScript(
          id: saved.id,
          name: saved.name,
          code: saved.code,
          origin: saved.url,
          isCustom: true,
        );
      } catch (e) {
        _scripts[saved.id] = LxScriptInfo.failed(
          id: saved.id,
          name: saved.name,
          origin: saved.url,
          error: e.toString(),
        );
      }
    }
  }

  /// Fetch a script from [url], validate + evaluate it, and persist it
  /// only after it loads and sends `inited`. Throws [LxScriptException]
  /// with a user-facing reason on any failure; nothing is saved then.
  Future<LxScriptInfo> addCustomScript(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw LxScriptException('请输入 http(s) 脚本链接');
    }
    String code;
    try {
      final res = await _dio.get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          validateStatus: (_) => true,
          headers: {'User-Agent': 'lx-music-request/1.0'},
        ),
      );
      if (res.statusCode != 200 || (res.data ?? '').isEmpty) {
        throw LxScriptException('下载失败 (HTTP ${res.statusCode})');
      }
      code = res.data!;
    } on LxScriptException {
      rethrow;
    } catch (e) {
      throw LxScriptException('下载失败: $e');
    }
    if (!code.contains('globalThis.lx') &&
        !code.contains("globalThis['lx']") &&
        !code.contains('globalThis["lx"]')) {
      throw LxScriptException('不是 LX 音乐源脚本 (缺少 globalThis.lx)');
    }
    final name = _parseMeta(code, 'name') ?? uri.host;
    final digest = sha1.convert(utf8.encode(uri.toString())).toString();
    final id = 'custom:${digest.substring(0, 12)}';
    final info = await _loadScript(
      id: id,
      name: name,
      code: code,
      origin: uri.toString(),
      isCustom: true,
    );
    await LxScriptSourcesStore.saveCustomScript(
      LxCustomScript(
        id: id,
        name: name,
        url: uri.toString(),
        code: code,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return info;
  }

  /// Import a script from picked-file contents (a .js file chosen in
  /// 音源管理), validating + evaluating it exactly like
  /// [addCustomScript]: the code must contain `globalThis.lx` and
  /// send `inited`, and it is persisted only after it loads. The id
  /// derives from the file CONTENT (not the name), so re-importing
  /// the same file replaces the old record instead of duplicating
  /// it; the name falls back to the file name when the script has
  /// no `@name`. Throws [LxScriptException] with a user-facing
  /// reason on any failure; nothing is saved then.
  ///
  /// Same ~10s `inited` wait as [_loadScript] — a slow script that
  /// defers `inited` (e.g. 原版念心 waits 4–5s for its update check)
  /// can be imported this way; a script that never sends `inited`
  /// still fails, bounded.
  Future<LxScriptInfo> addCustomScriptFromFile({
    required String fileName,
    required String code,
  }) async {
    // Same check as addCustomScript (kept inline on purpose: the
    // task forbids touching addCustomScript's logic).
    if (!code.contains('globalThis.lx') &&
        !code.contains("globalThis['lx']") &&
        !code.contains('globalThis["lx"]')) {
      throw LxScriptException('不是 LX 音乐源脚本 (缺少 globalThis.lx)');
    }
    final baseName = fileName.replaceFirst(
      RegExp(r'\.js$', caseSensitive: false),
      '',
    );
    final name = _parseMeta(code, 'name') ??
        (baseName.isNotEmpty ? baseName : '自定义脚本');
    final digest = sha1.convert(utf8.encode(code)).toString();
    final id = 'custom:file:${digest.substring(0, 12)}';
    final url = 'file://$fileName';
    final info = await _loadScript(
      id: id,
      name: name,
      code: code,
      origin: url,
      isCustom: true,
    );
    await LxScriptSourcesStore.saveCustomScript(
      LxCustomScript(
        id: id,
        name: name,
        url: url,
        code: code,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return info;
  }

  /// Remove any script (bundled or custom) by id: dispose its runtime,
  /// drop it from the registry, and persist the removal so it never
  /// comes back. Bundled: deletes the file copy and records the id in
  /// the deleted set, so it is never re-seeded or loaded again —
  /// including after an app restart. Custom: removes the Hive record
  /// (as before). A deleted bundled script can be added back via its
  /// URL ([addCustomScript]).
  Future<void> removeScript(String id) async {
    final wasCustom = _scripts[id]?.isCustom ?? id.startsWith('custom:');
    _runtimes.remove(id)?.dispose();
    _scripts.remove(id);
    if (wasCustom) {
      await LxScriptSourcesStore.removeCustomScript(id);
    } else {
      try {
        await _fileStore?.delete(id);
      } catch (_) {}
      await LxScriptSourcesStore.markBundledDeleted(id);
      // Drop any stale enable/disable entry for the removed script.
      await LxScriptSourcesStore.setEnabled(id, true);
    }
  }

  /// Remove a custom script (runtime + persisted record). Kept for
  /// existing callers; delegates to [removeScript].
  Future<void> removeCustomScript(String id) => removeScript(id);

  /// Load + evaluate one script in a fresh runtime. Returns the
  /// registered info; throws [LxScriptException] when the script does
  /// not evaluate or never sends `inited`.
  Future<LxScriptInfo> _loadScript({
    required String id,
    required String name,
    required String code,
    required String origin,
    required bool isCustom,
  }) async {
    if (_disposed) throw LxScriptException('engine disposed');
    _runtimes.remove(id)?.dispose();
    final rt = _ScriptRuntime(_runtimeFactory(), id);
    _runtimes[id] = rt;
    try {
      final pre = rt.js.evaluate(kLxPrelude);
      if (pre.isError) {
        throw LxScriptException('LX 环境初始化失败: ${pre.stringResult}');
      }
      // Stamp the script id the prelude's sendMessage calls carry:
      // the flutter_js static-callback routing (see _ScriptRuntime)
      // delivers every message stamped with this id to THIS runtime,
      // even when a newer runtime was created afterwards. Must run
      // before the script itself is evaluated.
      rt.js.evaluate(
        'globalThis.__haoLxScriptId = ${jsonEncode(id)};',
      );
      final ev = rt.js.evaluate(code);
      if (ev.isError) {
        throw LxScriptException('脚本执行失败: ${ev.stringResult}');
      }
      rt.js.executePendingJob();
      // Some scripts defer `inited` behind a timer (统一音乐源 used
      // to send it from setTimeout(100ms); 原版念心 waits 4–5s for
      // its update check). Poll so a deferred inited is still
      // accepted, early exit in the common synchronous case. The
      // loop also bails the moment this runtime stops being the
      // registered one (script removed / re-loaded mid-load): the
      // load must not register sources for a runtime that is gone.
      // Disposal itself is safe for late timers: prelude setTimeout
      // is routed through LxTimeout, and _fireTimeout drops the
      // callback once the runtime is unregistered — so a timer
      // firing after dispose never evaluates on a released
      // JSContext (the v1.0.7-class UAF this wait used to cause).
      final steps = initedTimeout.inMilliseconds ~/ 100;
      for (var i = 0; i < steps && !rt.initedReceived; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_runtimes[id] != rt) {
          throw LxScriptException('脚本已卸载: $id');
        }
      }
      if (_runtimes[id] != rt) {
        throw LxScriptException('脚本已卸载: $id');
      }
      if (!rt.initedReceived) {
        throw LxScriptException('脚本未发送 inited (不是有效的 LX 音源)');
      }
      if (rt.initedData?['status'] == false) {
        throw LxScriptException('脚本初始化失败 (status false)');
      }
      final sources = _parseSources(rt, name);
      final info = LxScriptInfo(
        id: id,
        name: _parseMeta(code, 'name') ?? name,
        version: _parseMeta(code, 'version') ?? '',
        origin: origin,
        isCustom: isCustom,
        loaded: true,
        sources: sources,
        configView: rt.configView,
        updateAlert: rt.lastUpdateAlert,
      );
      _scripts[id] = info;
      // Fire-and-forget: scripts issue checkUpdate at load; without a
      // pump those requests would sit until the next dispatch. This
      // completes them shortly after load (failures are silent).
      unawaited(_pumpHttp(rt).catchError((_) {}));
      return info;
    } catch (e) {
      // Identity-guarded: a re-load may already have replaced this
      // runtime — disposing the map entry then would kill the new
      // runtime. Only remove when this load's runtime is still the
      // registered one (the common failure path).
      if (_runtimes[id] == rt) {
        _runtimes.remove(id)?.dispose();
      }
      if (e is LxScriptException) rethrow;
      throw LxScriptException(e.toString());
    }
  }

  List<LxScriptSourceInfo> _parseSources(_ScriptRuntime rt, String name) {
    final out = <LxScriptSourceInfo>[];
    final raw = rt.initedData?['sources'];
    if (raw is! Map) return out;
    for (final entry in raw.entries) {
      final platform = entry.key.toString();
      // 'local' (落雪) is a local-file pseudo-source, not a music
      // platform — its musicUrl needs server_ ids we never produce.
      if (platform == 'local') continue;
      if (entry.value is! Map) continue;
      final m = Map<String, dynamic>.from(entry.value as Map);
      final actions = <String>[];
      final rawActions = m['actions'];
      if (rawActions is List) {
        for (final a in rawActions) {
          final s = a.toString();
          if (['musicUrl', 'search', 'pic', 'lyric'].contains(s)) {
            actions.add(s);
          }
        }
      }
      if (actions.isEmpty) continue;
      final qualities = <String>[];
      final rawQ = m['qualitys'] ?? m['qualities'];
      if (rawQ is List) {
        for (final q in rawQ) {
          qualities.add(q.toString());
        }
      }
      out.add(
        LxScriptSourceInfo(
          scriptId: rt.scriptId,
          scriptName: name,
          platform: platform,
          displayName: m['name']?.toString() ?? platform,
          actions: actions,
          qualities: qualities,
        ),
      );
    }
    return out;
  }

  static String? _parseMeta(String code, String key) {
    final m =
        RegExp('@$key\\s+([^\\r\\n*]+)').firstMatch(code);
    final v = m?.group(1)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  // -- script actions -------------------------------------------------------

  /// Low-level dispatch: invoke the script's `request` handler with
  /// [payload] ({action, source, info}) and await its result. Returns
  /// the raw JS value (String / List / Map / null). Throws
  /// [LxScriptException] on script error, [TimeoutException] on
  /// timeout. Prefer [getMusicUrl]/[search] unless you need a raw
  /// action (pic / lyric).
  Future<dynamic> requestAction({
    required String scriptId,
    required String action,
    required String source,
    required Map<String, dynamic> info,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final rt = _runtimes[scriptId];
    if (rt == null) {
      throw LxScriptException('脚本未加载: $scriptId');
    }
    final payload = {'action': action, 'source': source, 'info': info};
    final idRaw = rt.js
        .evaluate(
          '__haoLxDispatch(${jsonEncode('request')}, '
          '${jsonEncode(jsonEncode(payload))})',
        )
        .stringResult;
    final id = int.tryParse(idRaw);
    if (id == null) {
      throw LxScriptException('dispatch 失败: $idRaw');
    }
    final deadline = DateTime.now().add(timeout);
    while (true) {
      // The runtime may have been disposed/replaced while this dispatch
      // was in flight (script removed in settings). Evaluating on a
      // released JSContext is a native use-after-free — bail out
      // instead of polling a dead runtime.
      if (_runtimes[scriptId] != rt) {
        throw LxScriptException('脚本已卸载: $scriptId');
      }
      await _pumpHttp(rt);
      // _pumpHttp awaits HTTP: the runtime may have been disposed /
      // replaced while a request was in flight. Never evaluate the
      // dispatch result on a released JSContext — re-check identity
      // after the await, same guard as the loop top.
      if (_runtimes[scriptId] != rt) {
        throw LxScriptException('脚本已卸载: $scriptId');
      }
      final resRaw =
          rt.js.evaluate('__haoLxDispatchResult($id)').stringResult;
      Map<String, dynamic>? res;
      try {
        final decoded = jsonDecode(resRaw);
        if (decoded is Map<String, dynamic>) res = decoded;
      } catch (_) {}
      if (res != null && res['done'] == true) {
        if (res['ok'] == true) return res['value'];
        throw LxScriptException(
          res['error']?.toString() ?? '脚本执行失败',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('LX 脚本超时 ($action/$source)');
      }
      rt.js.executePendingJob();
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Perform every pending `lx.request` HTTP job for [rt] via Dio and
  /// deliver each result back into JS. Sequential: scripts issue
  /// requests one at a time.
  Future<void> _pumpHttp(_ScriptRuntime rt) async {
    while (rt.httpJobs.isNotEmpty) {
      // Same disposed-runtime guard as requestAction: never evaluate
      // on a JSContext that has been released.
      if (_runtimes[rt.scriptId] != rt) return;
      final job = rt.httpJobs.removeAt(0);
      String? err;
      String? respJson;
      try {
        final timeout = job.timeoutMs > 0
            ? Duration(milliseconds: job.timeoutMs)
            : const Duration(seconds: 8);
        final res = await _dio.request<String>(
          job.url,
          data: job.body,
          options: Options(
            method: job.method,
            headers: job.headers,
            responseType: ResponseType.plain,
            validateStatus: (_) => true,
            receiveTimeout: timeout,
            sendTimeout: timeout,
          ),
        );
        dynamic body = res.data ?? '';
        if (body is String) {
          try {
            body = jsonDecode(body);
          } catch (_) {}
        }
        respJson = jsonEncode({
          'statusCode': res.statusCode ?? 0,
          'headers': {
            for (final e in res.headers.map.entries)
              e.key: e.value.join(', '),
          },
          'body': body,
        });
      } catch (e) {
        err = e.toString();
      }
      // The Dio request above awaited: the script may have been
      // removed mid-flight (settings → delete). Delivering into a
      // released JSContext is a native use-after-free — drop the
      // result and stop pumping instead. Same identity guard as the
      // loop top, re-checked after EVERY await.
      if (_runtimes[rt.scriptId] != rt) return;
      rt.js.evaluate(
        '__haoLxDeliver(${job.id}, ${jsonEncode(err)}, '
        '${jsonEncode(respJson)})',
      );
      rt.js.executePendingJob();
    }
  }

  /// Play URL for [song] on [platform] at [quality] via one script.
  /// Returns null when the script cannot serve this platform/quality
  /// or the lookup fails (the resolver chain then downgrades).
  /// [musicInfo] is the LX musicInfo map; defaults to the Song-derived
  /// shape when omitted.
  Future<String?> getMusicUrl({
    required String scriptId,
    required String platform,
    required Song song,
    required AudioQuality quality,
    Map<String, dynamic>? musicInfo,
  }) async {
    final r = await getMusicUrlWithTier(
      scriptId: scriptId,
      platform: platform,
      song: song,
      quality: quality,
      musicInfo: musicInfo,
    );
    return r?.url;
  }

  /// Pure tier check for a script-reported tier string (P1-L1): at
  /// a master request, only a literal `'master'` report keeps master;
  /// any other report is hires. Other requests keep the declared
  /// label (null). Kept separate so it is unit-testable without a JS
  /// runtime.
  static AudioQuality? reportedTierFor({
    required String? reported,
    required AudioQuality requested,
  }) {
    if (requested != AudioQuality.master || reported == null) return null;
    return reported == 'master' ? AudioQuality.master : AudioQuality.hires;
  }

  /// Play URL + the tier the script actually served, for the resolver
  /// loop's Master gate (P1-L1). Most scripts return a bare URL
  /// string — no tier signal — so the job only exists when the script
  /// declares the tier (see [scriptJobsFor]) and the declared label
  /// stands (`actualQuality` null). A script that returns a
  /// `{url, quality}` / `{url, type}` map is held to the tier it
  /// reports: at a master request anything but `'master'` is hires,
  /// never master. Other tiers keep the declared label.
  Future<({String url, AudioQuality? actualQuality})?> getMusicUrlWithTier({
    required String scriptId,
    required String platform,
    required Song song,
    required AudioQuality quality,
    Map<String, dynamic>? musicInfo,
  }) async {
    final info = _scripts[scriptId];
    if (info == null || !info.loaded) return null;
    final src = info.sourceFor(platform);
    if (src == null || !src.supportsMusicUrl) return null;
    final qStr = lxQualityForScript(quality, src.qualities);
    if (qStr == null) return null;
    final mi = <String, dynamic>{
      ...(musicInfo ??
          {
            'songmid': song.songId,
            'id': song.songId,
            'name': song.title,
            'singer': song.artist,
            'albumName': song.album,
          }),
      // LX musicInfo carries the platform; some scripts (统一音乐源)
      // read musicInfo.source instead of the dispatch top-level
      // source. Additive only — scripts that ignore it are unaffected.
      'source': platform,
    };
    try {
      final v = await requestAction(
        scriptId: scriptId,
        action: 'musicUrl',
        source: platform,
        info: {'musicInfo': mi, 'type': qStr},
      );
      if (v is String && v.isNotEmpty) {
        return (url: toHttps(v), actualQuality: null);
      }
      if (v is Map) {
        final rawUrl = v['url']?.toString() ?? '';
        if (rawUrl.isEmpty) return null;
        final reported =
            v['quality']?.toString() ?? v['type']?.toString();
        return (
          url: toHttps(rawUrl),
          actualQuality:
              reportedTierFor(reported: reported, requested: quality),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Search via one script (only scripts declaring `search` for the
  /// platform). Returns raw result maps; use [lxSongFromJson] to map
  /// them to [Song]. Returns [] on any failure.
  ///
  /// Two shapes are accepted (verified 2026-11-17 with the real
  /// scripts): a bare list (溯音 / 非常刀) and the LX-standard
  /// `{isEnd, list}` object (裤佬). Before, the object shape was
  /// silently dropped, so the 裤佬 leg could never contribute.
  /// `text` is sent alongside `keyword`: 裤佬 reads `info.text`,
  /// 溯音 / 非常刀 read `info.keyword` — additive, neither side
  /// is affected by the extra key.
  /// Timeout is 5 s, matching the caller's deadline in
  /// [SongSearchService.searchAllStream]: a longer inner timeout only
  /// leaves the requestAction poll loop evaluating JS after the
  /// caller has already discarded the result.
  Future<List<Map<String, dynamic>>> search({
    required String scriptId,
    required String platform,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async {
    final info = _scripts[scriptId];
    if (info == null || !info.loaded) return const [];
    final src = info.sourceFor(platform);
    if (src == null || !src.supportsSearch) return const [];
    try {
      final v = await requestAction(
        scriptId: scriptId,
        action: 'search',
        source: platform,
        info: {'keyword': keyword, 'text': keyword, 'page': page, 'limit': limit},
        timeout: const Duration(seconds: 5),
      );
      return unwrapSearchResult(v);
    } catch (_) {
      return const [];
    }
  }

  /// Unwrap a script search result into raw song maps. Pure function
  /// (unit-tested): bare list, or the LX-standard `{isEnd, list}`
  /// object; anything else is [].
  static List<Map<String, dynamic>> unwrapSearchResult(dynamic v) {
    if (v is List) {
      return [
        for (final e in v)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    if (v is Map) {
      final list = v['list'];
      if (list is List) {
        return [
          for (final e in list)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
    }
    return const [];
  }

  /// Script search results use LX's song shape
  /// ({name, singer, albumName, id, interval 'mm:ss', meta.picture}).
  /// Returns null when the record is unusable.
  static Song? lxSongFromJson(Map<String, dynamic> j, MusicPlatform pf) {
    final id = j['id']?.toString() ?? j['songmid']?.toString() ?? '';
    final title = j['name']?.toString() ?? '';
    if (id.isEmpty || title.isEmpty) return null;
    var dur = 0;
    final m =
        RegExp(r'^(\d+):(\d{2})$').firstMatch(j['interval']?.toString() ?? '');
    if (m != null) {
      dur = (int.tryParse(m.group(1) ?? '') ?? 0) * 60 +
          (int.tryParse(m.group(2) ?? '') ?? 0);
    }
    final meta = j['meta'];
    return Song(
      songId: id,
      title: title,
      artist: j['singer']?.toString() ?? '',
      album: j['albumName']?.toString() ?? j['album']?.toString() ?? '',
      cover: meta is Map ? meta['picture']?.toString() ?? '' : '',
      platform: pf,
      dur: dur,
    );
  }

  /// MusicInfo map for a [Song] in LX shape (used by the resolver
  /// integration and tests).
  static Map<String, dynamic> musicInfoFor(Song song) => {
        'songmid': song.songId,
        'id': song.songId,
        'name': song.title,
        'singer': song.artist,
        'albumName': song.album,
      };

  /// Script jobs for the resolver loop: every enabled script source
  /// that serves [platform] at [quality], as (key, name, fn).
  /// A script job only exists when the script declares the quality —
  /// a script that lists only 128k/320k never gets a hires job.
  /// The fn reports the tier the script actually served when the
  /// script reports one (see [getMusicUrlWithTier], P1-L1).
  List<
    ({
      String key,
      String name,
      Future<({String url, AudioQuality? actualQuality})> Function() fn,
    })
  >
      scriptJobsFor(
    MusicPlatform platform,
    AudioQuality quality,
    Song song,
  ) {
    final out = <({String key, String name, Future<({String url, AudioQuality? actualQuality})> Function() fn})>[];
    for (final info in _scripts.values) {
      if (!info.loaded) continue;
      if (!LxScriptSourcesStore.isEnabled(info.id)) continue;
      final src = info.sourceFor(platform.code);
      if (src == null || !src.supportsMusicUrl) continue;
      if (lxQualityForScript(quality, src.qualities) == null) continue;
      out.add(
        (
          key: 'lx:${info.id}',
          name: info.name,
          fn: () async =>
              await getMusicUrlWithTier(
                scriptId: info.id,
                platform: platform.code,
                song: song,
                quality: quality,
              ) ??
              (url: '', actualQuality: null),
        ),
      );
    }
    return out;
  }

  /// Script search legs for aggregated search: every enabled script
  /// source declaring `search` for [platform].
  List<({String scriptId, String scriptName})> searchLegsFor(
    MusicPlatform platform,
  ) {
    final out = <({String scriptId, String scriptName})>[];
    for (final info in _scripts.values) {
      if (!info.loaded) continue;
      if (!LxScriptSourcesStore.isEnabled(info.id)) continue;
      final src = info.sourceFor(platform.code);
      if (src == null || !src.supportsSearch) continue;
      out.add((scriptId: info.id, scriptName: info.name));
    }
    return out;
  }

  /// Console lines captured from [scriptId] (last 100, oldest first).
  List<String> logsFor(String scriptId) =>
      List.unmodifiable(_runtimes[scriptId]?.logs ?? const []);

  /// Last updateAlert payload this script sent, if any (arrives
  /// asynchronously via checkUpdate — may be null right after load).
  Map<String, dynamic>? lastUpdateAlert(String scriptId) =>
      _runtimes[scriptId]?.lastUpdateAlert;

  /// Last showConfigView payload this script sent, if any.
  Map<String, dynamic>? configViewFor(String scriptId) =>
      _runtimes[scriptId]?.configView;

  void dispose() {
    _disposed = true;
    for (final rt in _runtimes.values) {
      rt.dispose();
    }
    _runtimes.clear();
  }
}
