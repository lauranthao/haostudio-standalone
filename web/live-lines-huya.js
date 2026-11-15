// ---- Huya live lines (Pure Live port) — live-lines-huya.js ----
// Port of Pure Live `packages/live_core/lib/src/sites/huya/`:
//   HuyaApi.signAntiCode / rotateUid / unrotateUid / mediaQuery /
//   mediaUrl / replaceQueryParameter / anonymousUid / fallbackViewerUid
//   (huya_api.dart)
//   HuyaSite._requestAnonymousUid / _viewerUid / _sign / _open
//   (huya_site.dart)
//
// LOAD ORDER: this file loads AFTER app.js, so the `function`
// declarations below override the versions in app.js. Only `function`
// declarations and `var HUYA_LL_*` names are used here (no const/let
// at top level, so no app.js name can be redefined).
//
// WHAT CHANGED vs the old directHuyaPlayFlv in app.js:
//   - Old: reused the desktop page's sFlvAntiCode directly — it
//     expires ~5 min after the page was served (wsTime + 300 s), so
//     every expiry needed a full room-page re-fetch.
//   - New: the anti-code is re-signed CLIENT-SIDE (port of
//     HuyaApi.signAntiCode): the base64 `fm` template ($0-$3) is
//     decoded, $0 = rotated uid, $1 = stream name, $2 =
//     md5("$seqId|$ctype|$platform"), $3 = wsTime, and wsSecret =
//     md5(template). directMd5 from app.js is reused for both md5s.
//     directHuyaSign(antiCode, streamName, uid) does the re-sign;
//     HUYA_LL_rebuildFlvUrls(play, signedAntiCode) rebuilds the
//     5 qualities x 3 lines from the stored room data — no page
//     re-fetch while the credential is still valid.
//   - Anonymous uid: udblgn.huya.com/web/anonymousLogin (port of
//     HuyaSite._requestAnonymousUid), cached; falls back to a local
//     temporary uid (1400000000000 + random, port of
//     HuyaApi.fallbackViewerUid) when that call fails.
//   - URL building is the ported mediaQuery/mediaUrl: codec=264 is
//     added when absent, ratio=<rate> is set per quality (removed
//     for the source, rate 0), so the FLV address is
//     sFlvUrl + '/' + sStreamName + '.flv?' + antiCode.
//   - Return shape is now {url, type:'flv', quality:'0',
//     qualities:[{id, name, bitrate, urls:[...]}], signExpiresAt,
//     streamName, antiCode, flvHosts, flvPrefix, rates} — every
//     quality carries one URL per CDN line (AL/TX/HS, server order),
//     `url` is qualities[0].urls[0] for compatibility, and
//     signExpiresAt is the (wsTime + 300 s) hard expiry in ms.
//     The caller should re-sign BEFORE signExpiresAt (Pure Live
//     refreshes 30 s early, i.e. at wsTime + 270 s); see below.
//
// HONEST LIMIT (Pure Live REG-HUYA-004, huya_api.dart): re-signing
// does NOT extend the credential. signAntiCode keeps the ORIGINAL
// wsTime and throws `expired` once now > wsTime + 300 s — "the
// credential must be fetched again, never extended locally". So
// directHuyaSign works only inside the original 5-minute window
// (refresh a live connection before it ends); past wsTime + 300 s
// the caller MUST re-fetch the room page (directHuyaPlayFlv) for a
// fresh sFlvAntiCode. signExpiresAt is exactly that deadline.
// (The first version of this file is also the reason the initial
// play still uses the page's own anti-code unchanged — that path is
// verified working; the re-signed path is verified by the smoke
// test, see the report, and is used for refreshes.)
//
// INTEGRATION (coordinator): add
//   <script src="./live-lines-huya.js"></script>
// AFTER app.js in web/index.html. Nothing else in app.js needs to
// change: directLivePlay('huya',...) calls directHuyaPlay, which
// calls this directHuyaPlayFlv, and liveCurUrls()/liveLines() already
// consume qualities[].urls. On expiry the caller does:
//   const signed = await directHuyaSign(play.antiCode,
//                                        play.streamName, play.uid);
//   const fresh = HUYA_LL_rebuildFlvUrls(play, signed);
//   // fresh.qualities / fresh.url replace play.qualities / play.url
// If directHuyaSign throws with .code === 'expired', re-fetch the
// page instead (directHuyaPlayFlv). The nativeFetch allowlist needs
// ONE new host for this file — udblgn.huya.com (see the host list
// at the end).

// Mobile Chrome UA of HuyaApi.userAgent (huya_api.dart) — used for
// the anonymous-login request.
var HUYA_LL_UA = 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0';
// Anti-code validity after its wsTime (HuyaApi.signAntiCode).
var HUYA_LL_SIGN_VALIDITY_S = 300;
// Refresh lead: Pure Live's lease refreshes 30 s before expiry.
var HUYA_LL_SIGN_REFRESH_LEAD_S = 30;
// HuyaSignClock._last: signing ms, never behind the wall clock and
// strictly increasing, so two signs in the same millisecond still
// get different seqid/wsSecret (huya_api.dart).
var HUYA_LL_lastSignMillis = 0;
// Cached anonymous uid (HuyaSite._anonymousUid).
var HUYA_LL_anonymousUid = 0;

// Port of HuyaApi.rotateUid: `u = rotl64(uid)` — the low 32 bits
// rotate left by 8, the high 32 bits stay (REG-HUYA-008: anonymous
// uids are above 2^32, so this must NOT be a 32-bit JS bitwise op
// on the whole uid). Uses arithmetic so uids above 2^32 survive.
function HUYA_LL_rotateUid(uid) {
  uid = Math.floor(Number(uid));
  var low = uid % 4294967296;
  var high = uid - low;
  var rot = ((low * 256) % 4294967296 + Math.floor(low / 16777216)) >>> 0;
  return high + rot;
}

// Port of HuyaSignClock.next: the next signing millisecond at
// `nowMs`, never behind the wall clock, strictly increasing.
function HUYA_LL_nextSignMillis(nowMs) {
  var w = Math.floor(nowMs);
  HUYA_LL_lastSignMillis = w > HUYA_LL_lastSignMillis ? w : HUYA_LL_lastSignMillis + 1;
  return HUYA_LL_lastSignMillis;
}

// Port of Dart `_parse` (huya_api.dart): a query split without
// decoding (tokens may carry stray `%`); the first value of a
// repeated key wins; the original segment spelling is kept in `raw`.
function HUYA_LL_parseAntiCode(query) {
  var params = [];
  var seen = {};
  var parts = String(query || '').trim().split('&');
  for (var i = 0; i < parts.length; i++) {
    var seg = parts[i];
    if (!seg) continue;
    var eq = seg.indexOf('=');
    var key = eq < 0 ? seg : seg.substring(0, eq);
    if (seen[key]) continue;
    seen[key] = true;
    params.push({ key: key, value: eq < 0 ? '' : seg.substring(eq + 1), raw: seg });
  }
  return params;
}

// Port of HuyaApi.signAntiCode's `value(key)`: first match,
// percent-decoded + trimmed; throws {code:'malformed'} on a stray
// `%` or undecodable value. Returns null when the key is absent.
function HUYA_LL_antiCodeValue(params, key) {
  for (var i = 0; i < params.length; i++) {
    if (params[i].key !== key) continue;
    var v = params[i].value;
    if (/%(?![0-9A-Fa-f]{2})/.test(v)) {
      var e = new Error('huya sign malformed: ' + key + ' is not percent-encoded UTF-8');
      e.code = 'malformed';
      throw e;
    }
    try {
      return decodeURIComponent(v).trim();
    } catch (err) {
      var e2 = new Error('huya sign malformed: ' + key + ' is not percent-encoded UTF-8');
      e2.code = 'malformed';
      throw e2;
    }
  }
  return null;
}

// base64.normalize + base64.decode + utf8.decode (Dart): strip
// whitespace, pad to a multiple of 4, decode to a UTF-8 string.
// Throws on bad base64 / bad UTF-8 (caller maps to `malformed`).
function HUYA_LL_b64Utf8(b64) {
  var s = String(b64).replace(/\s+/g, '');
  while (s.length % 4) s += '=';
  var bin;
  if (typeof atob === 'function') bin = atob(s);
  else bin = Buffer.from(s, 'base64').toString('latin1');
  var bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
  if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  return decodeURIComponent(escape(bin));
}

// Port of Dart `_wsTime`: `wsTime` is hexadecimal Unix seconds;
// null when missing/invalid (<= 0 or above 0xFFFFFFFFFF).
function HUYA_LL_wsTimeSeconds(antiCode) {
  var params = HUYA_LL_parseAntiCode(antiCode);
  for (var i = 0; i < params.length; i++) {
    if (params[i].key !== 'wsTime') continue;
    var v;
    try {
      v = decodeURIComponent(params[i].value).trim().toLowerCase();
    } catch (e) {
      return null;
    }
    if (!/^[0-9a-f]+$/.test(v)) return null;
    var s = parseInt(v, 16);
    if (!(s > 0) || s > 0xFFFFFFFFFF) return null;
    return s;
  }
  return null;
}

// Hard expiry of an (original or re-signed) anti-code in ms since
// epoch: wsTime + 300 s. Null when the anti-code has no wsTime.
function HUYA_LL_signExpiresAt(antiCode) {
  var s = HUYA_LL_wsTimeSeconds(antiCode);
  return s === null ? null : (s + HUYA_LL_SIGN_VALIDITY_S) * 1000;
}

// Port of HuyaApi.replaceQueryParameter: `query` with the first
// `key` set to `value` in place and later ones removed; appended
// when absent; removed entirely when `value` is null. Empty
// segments are dropped.
function HUYA_LL_replaceQueryParam(query, key, value) {
  var out = [];
  var replaced = false;
  var parts = String(query).split('&');
  for (var i = 0; i < parts.length; i++) {
    var seg = parts[i];
    if (!seg) continue;
    var eq = seg.indexOf('=');
    var k = eq < 0 ? seg : seg.substring(0, eq);
    if (k !== key) {
      out.push(seg);
      continue;
    }
    if (!replaced && value !== null && value !== undefined) out.push(key + '=' + value);
    replaced = true;
  }
  if (!replaced && value !== null && value !== undefined) out.push(key + '=' + value);
  return out.join('&');
}

// Port of HuyaApi.mediaQuery: `codec=264` added when absent
// (`codec=265` with hevc); `ratio` set to the rate, or removed for
// the source (0) — never the ratio captured with the page
// (REG-HUYA-012).
function HUYA_LL_mediaQuery(antiCode, bitRate, hevc) {
  var q = /(^|&)codec=/.test(antiCode) ? antiCode : antiCode + '&codec=' + (hevc ? 265 : 264);
  return HUYA_LL_replaceQueryParam(q, 'ratio', bitRate > 0 ? String(bitRate) : null);
}

// Port of HuyaApi.mediaUrl: `{base}/{streamName}.{flv|m3u8}?{query}`.
// hevc asks an FLV line for HEVC; HLS always asks for H.264.
function HUYA_LL_mediaUrl(base, streamName, antiCode, bitRate, hevc, format) {
  var b = String(base || '').replace(/\/+$/, '');
  var ext = format === 'm3u8' ? 'm3u8' : 'flv';
  var q = HUYA_LL_mediaQuery(antiCode, bitRate, hevc && ext === 'flv');
  return b + '/' + streamName + '.' + ext + '?' + q;
}

// Port of HuyaApi.fallbackViewerUid: a local temporary viewer uid
// for when anonymous login fails — 1400000000000 plus a uniform
// value below 10^11 (REG-HUYA-017). Never cached as the official
// identity: the next sign asks anonymous login again.
function HUYA_LL_fallbackUid() {
  return 1400000000000 + Math.floor(Math.random() * 1000000) * 100000 + Math.floor(Math.random() * 100000);
}

// Port of HuyaSite._requestAnonymousUid + HuyaApi.anonymousUid:
// POST udblgn.huya.com/web/anonymousLogin -> data.uid. Returns the
// cached uid, else null on any failure (caller falls back).
async function HUYA_LL_requestAnonymousUid() {
  if (HUYA_LL_anonymousUid > 0) return HUYA_LL_anonymousUid;
  try {
    var j = await nativeJson('https://udblgn.huya.com/web/anonymousLogin', {
      method: 'POST',
      headers: {
        'User-Agent': HUYA_LL_UA,
        'Accept': '*/*',
        'Origin': 'https://www.huya.com',
        'Referer': 'https://www.huya.com/',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ appId: 5002, byPass: 3, context: '', version: '2.4', data: {} })
    }, 10000);
    var uid = j && j.data && Number(j.data.uid);
    if (uid > 0) {
      HUYA_LL_anonymousUid = uid;
      return uid;
    }
  } catch (e) {}
  return null;
}

// Port of HuyaApi.signAntiCode (huya_api.dart, 3.x `buildAntiCode`).
// Signs `antiCode` for `streamName` as `uid`. A query without an
// `fm` value is returned unchanged. Parameters the signer does not
// own keep their spelling and position.
//   seqid = uid + clock.next(now); hash = md5("seqid|ctype|t");
//   ctype defaults to `huya_webh5`, t to `100`; t=103 is WAP.
//   wsSecret = md5(template) with $0 = rotated uid (the uid itself
//   for WAP), $1 = stream, $2 = hash, $3 = wsTime (lower case).
//   Output: `wsSecret seqid u uid uuid fm` removed, then wsSecret,
//   wsTime, seqid, ctype, ver=1, fs (default `bgct`), t, and u
//   (WAP: `uid` and a random `uuid`), an existing key replaced in
//   place, a missing one appended.
// Throws Error with .code 'malformed' (no hex wsTime, an `fm` that
// does not decode, or a template without all of $0-$3) or 'expired'
// (past wsTime + 300 s — the credential must be fetched again,
// never extended locally, REG-HUYA-004).
// `nowMs` is injectable for tests; defaults to Date.now().
function HUYA_LL_signAntiCode(antiCode, streamName, uid, nowMs) {
  function malformed(reason) {
    var e = new Error('huya sign malformed: ' + reason);
    e.code = 'malformed';
    return e;
  }
  function expired(reason) {
    var e = new Error('huya sign expired: ' + reason);
    e.code = 'expired';
    return e;
  }
  function orDefault(value, fallback) {
    return value === null || value === undefined || value === '' ? fallback : value;
  }
  var params = HUYA_LL_parseAntiCode(antiCode);
  var fm = HUYA_LL_antiCodeValue(params, 'fm') || '';
  if (!fm) return antiCode;
  if (!(uid > 0)) throw malformed('no signing uid');
  var ctype = orDefault(HUYA_LL_antiCodeValue(params, 'ctype'), 'huya_webh5');
  var platform = orDefault(HUYA_LL_antiCodeValue(params, 't'), '100');
  var wap = platform === '103';
  var wsTime = (HUYA_LL_antiCodeValue(params, 'wsTime') || '').toLowerCase();
  var wsSeconds = /^[0-9a-f]+$/.test(wsTime) ? parseInt(wsTime, 16) : null;
  if (wsSeconds === null || !(wsSeconds > 0)) throw malformed('no hexadecimal wsTime');
  var template;
  try {
    template = HUYA_LL_b64Utf8(fm);
  } catch (e) {
    throw malformed('fm is not base64 UTF-8');
  }
  if (['$0', '$1', '$2', '$3'].some(function (p) { return template.indexOf(p) < 0; })) {
    throw malformed('fm template lacks $0-$3');
  }
  var millis = HUYA_LL_nextSignMillis(nowMs === undefined || nowMs === null ? Date.now() : nowMs);
  if (Math.floor(millis / 1000) > wsSeconds + HUYA_LL_SIGN_VALIDITY_S) {
    throw expired('wsTime + 300 s has passed');
  }
  var seqId = uid + millis;
  var hash = directMd5(seqId + '|' + ctype + '|' + platform);
  var rotated = HUYA_LL_rotateUid(uid);
  // Replacer functions: the values are used literally (a stream
  // name containing `$` must not be treated as a $-pattern).
  var secret = template
    .replace('$0', function () { return String(wap ? uid : rotated); })
    .replace('$1', function () { return streamName; })
    .replace('$2', function () { return hash; })
    .replace('$3', function () { return wsTime; });
  var wsSecret = directMd5(secret);
  var out = [];
  for (var i = 0; i < params.length; i++) {
    var k = params[i].key;
    if (k === 'wsSecret' || k === 'seqid' || k === 'u' || k === 'uid' || k === 'uuid' || k === 'fm') continue;
    out.push({ key: k, raw: params[i].raw });
  }
  function put(key, value) {
    var seg = { key: key, raw: key + '=' + encodeURIComponent(value) };
    for (var j = 0; j < out.length; j++) {
      if (out[j].key === key) {
        out[j] = seg;
        return;
      }
    }
    out.push(seg);
  }
  put('wsSecret', wsSecret);
  put('wsTime', wsTime);
  put('seqid', String(seqId));
  put('ctype', ctype);
  put('ver', '1');
  var fsv = HUYA_LL_antiCodeValue(params, 'fs');
  put('fs', fsv === null ? 'bgct' : fsv);
  put('t', platform);
  if (wap) {
    var ct = Math.floor((wsSeconds + Math.random()) * 1000);
    var uuid = Math.floor((((ct % 1e10) + Math.random()) * 1e3) % 0xffffffff);
    put('uid', String(uid));
    put('uuid', String(uuid));
  } else {
    put('u', String(rotated));
  }
  return out.map(function (p) { return p.raw; }).join('&');
}

// Caller-facing re-sign: re-signs `antiCode` for `streamName`.
// `uid` may be omitted — then the anonymous uid is fetched first
// (cached), and a local fallback uid is used if that fails (port of
// HuyaSite._viewerUid). Returns the re-signed anti-code string.
// Throws with .code 'expired' past wsTime + 300 s — then the caller
// must re-fetch the room page instead of re-signing. Throws with
// .code 'malformed' when the anti-code cannot be signed at all.
async function directHuyaSign(antiCode, streamName, uid) {
  var u = Number(uid);
  if (!(u > 0)) {
    u = await HUYA_LL_requestAnonymousUid();
    if (!(u > 0)) u = HUYA_LL_fallbackUid();
  }
  return HUYA_LL_signAntiCode(antiCode, streamName, u);
}

// Builds the full play result from parsed room-page data. Shared by
// directHuyaPlayFlv (initial play, page anti-code as-is) and
// HUYA_LL_rebuildFlvUrls (refresh, re-signed anti-code).
function HUYA_LL_buildFlvResult(hosts, prefix, streamName, antiCode, rates) {
  function lineUrls(rate) {
    return hosts.map(function (host) {
      return directLiveToHttps(HUYA_LL_mediaUrl('https://' + host + prefix, streamName, antiCode, rate));
    });
  }
  var qualities = rates.map(function (x) {
    return {
      id: String(x.rate),
      name: x.rate === 0 ? '原画' : (x.name || directHuyaQName(x.rate)),
      bitrate: x.rate > 0 ? x.rate * 1000 : null,
      urls: lineUrls(x.rate)
    };
  });
  return {
    url: qualities.length ? qualities[0].urls[0] : '',
    type: 'flv',
    quality: '0',
    qualities: qualities,
    signExpiresAt: HUYA_LL_signExpiresAt(antiCode),
    streamName: streamName,
    antiCode: antiCode,
    flvHosts: hosts.slice(),
    flvPrefix: prefix,
    rates: rates.map(function (x) { return { rate: x.rate, name: x.name }; })
  };
}

// Rebuilds {url, qualities, signExpiresAt} for an already-fetched
// room from a RE-SIGNED anti-code (directHuyaSign). No page fetch.
// The returned signExpiresAt is unchanged by re-signing (wsTime is
// kept); the caller should already have re-signed before it.
function HUYA_LL_rebuildFlvUrls(play, antiCode) {
  var hosts = (play && play.flvHosts) || [];
  var prefix = (play && play.flvPrefix) || '';
  var nm = play && play.streamName;
  var rates = (play && play.rates) || [{ rate: 0, name: '原画' }];
  return HUYA_LL_buildFlvResult(hosts, prefix, nm, antiCode, rates);
}

// ---- directHuyaPlayFlv (override of app.js) ----
// FLV first: the desktop room page exposes sFlvUrl + sStreamName +
// sFlvAntiCode, a plain FLV stream that plays in ijkplayer like Douyu.
// HLS is broken in ijkplayer (segments carry a ?EXTINF= query that
// FFmpeg 4 blocks), so HLS is only a fallback. Desktop FLV verified
// 2026-11-16 (flv/h264 on al, tx AND hs; qualities via &ratio=<rate>
// from vMultiStreamInfo 8000/4000/2000/500; the mobile page's FLV
// anti-code 403s on the FLV CDN).
// This override keeps that proven first-play behaviour (the page's
// own anti-code, unchanged) and only ADDS: ported mediaQuery/mediaUrl
// URL building (codec=264 when absent, ratio per quality), bitrate
// per quality, signExpiresAt, and the room data a refresh needs
// (streamName / antiCode / flvHosts / flvPrefix / rates).
async function directHuyaPlayFlv(roomId) {
  const html = await nativeText('https://www.huya.com/' + encodeURIComponent(roomId), { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://www.huya.com/' } }, 12000);
  function strOf(key) { const m = html.match(new RegExp('"' + key + '":"((?:\\\\.|[^"\\\\])*)"')); return m ? m[1].replace(/\\\\u002F/g, '/') : ''; }
  const fu = strOf('sFlvUrl'), nm = strOf('sStreamName'), fc = strOf('sFlvAntiCode');
  if (!fu || !nm || !fc) return null;
  // All CDN lines in server order (gameStreamInfoList: AL, TX, HS share
  // one stream name + anti-code — verified 2026-11-16). Pure Live lists
  // every multiLine entry the same way; HS verified working (flv/h264
  // 1080p) — the old "HS 403s" note was a transient/proxy artefact.
  const prefix = fu.replace(/^https?:\/\/[^\/]+/, '').replace(/\/+$/, '');
  const hosts = [];
  const hm = html.match(/"sFlvUrl":"https?:\/\/([^"\/]+)/g) || [];
  for (const h of hm) { const host = h.split('://')[1]; if (host && hosts.indexOf(host) < 0) hosts.push(host); }
  if (!hosts.length) hosts.push(fu.replace(/^https?:\/\//, '').split('/')[0]);
  // Qualities from the room's vMultiStreamInfo (Pure Live reads the same
  // list as liveData.bitRateInfo / stream.flv.rateArray): rate 0 is the
  // source (原画), the rest are transcodes selected by &ratio=<rate> on
  // the SAME anti-code — ffprobe-verified 2026-11-16 on room 770714
  // (8000: 1920x1080/8192k, 4000: 1920x1080/4096k, 2000: 1280x720/2048k,
  // 500: 800x450/512k). Without the list, one 原画 only — no invented
  // transcode (Pure Live REG-HUYA-013).
  let rates = [];
  const vm = html.match(/"vMultiStreamInfo":(\[[^\]]*\])/);
  if (vm) {
    try {
      const arr = JSON.parse(vm[1]);
      for (const it of arr) {
        const r = Number(it && it.iBitRate);
        const n = String((it && it.sDisplayName) || '');
        if (Number.isFinite(r) && r >= 0 && n) rates.push({ rate: r, name: n });
      }
    } catch (e) {}
  }
  const seenRate = {};
  rates = rates.filter(function (x) { if (seenRate[x.rate]) return false; seenRate[x.rate] = true; return true; });
  rates.sort(function (a, b) { const ka = a.rate === 0 ? 1e9 : a.rate, kb = b.rate === 0 ? 1e9 : b.rate; return kb - ka; });
  if (!rates.length) rates = [{ rate: 0, name: '原画' }];
  return HUYA_LL_buildFlvResult(hosts, prefix, nm, fc, rates);
}

// ---- API hosts used by this file (nativeFetch allowlist) ----
// Already allowlisted (used by app.js too):
//   www.huya.com        — desktop room page (directHuyaPlayFlv)
//   m.huya.com          — mobile room page (directHuyaPlayHls, app.js)
//   search.cdn.huya.com — real search (app.js)
// NEW — must be added to ViewController.swift's allowlist, or the
// anonymous-login call falls back to a local temporary uid:
//   udblgn.huya.com     — POST /web/anonymousLogin (anonymous uid)
// FLV media itself is fetched by the native player (ijkplayer), not
// by nativeFetch: the CDN hosts come from the room page's sFlvUrl
// (AL/TX/HS lines, e.g. *.huya.com / liveplay CDN hosts) and need no
// allowlist entry.
