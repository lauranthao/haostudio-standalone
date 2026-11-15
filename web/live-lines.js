// ---- live-lines.js — Pure Live Big-5 live lines (assembled) ----
// Loads AFTER app.js; the function declarations below override the
// single-quality / single-line versions in app.js. Each platform file
// is prefixed (BILI_LL_ / DOUYU_LL_ / HUYA_LL_ / DOUYIN_LL_ / KS_LL_)
// so nothing collides with app.js names. Activation: index.html must
// load this file after app.js (see integrate_live_lines.py).
// DO NOT edit app.js by hand to integrate — run the patch script.

// ---- Bilibili live lines (Pure Live port) — live-lines-bili.js ----
// Port of Pure Live `packages/live_core/lib/src/sites/bilibili/`:
//   BilibiliApi.qualities / resolution / _playurl / _codecs / _qnNames /
//   _compareCandidates / _formatRank / mixinKey / wbiQuery / buvid /
//   cookie / danmakuInfo / lease  (bilibili_api.dart)
//   BilibiliSite._play (qn=0) / _signed / wbiSign / _keys / _buvid /
//   _cookie / danmakuArgs (4 attempts, WBI keys renewed on attempts
//   2 and 4) / _accessId  (bilibili_site.dart)
//
// LOAD ORDER: this file loads AFTER app.js, so the `function`
// declarations below override the single-quality versions in app.js.
// Only `function` declarations are used here (no const/let at top
// level, so no app.js name can be redefined); every new name carries
// the BILI_LL_ prefix (same convention as live-lines-douyu.js).
//
// WHAT CHANGED vs the old directBiliPlay in app.js:
//   - Old: getRoomPlayInfo with qn=250 FIXED, http_hls only, ts+fmp4,
//     avc only, one quality, no cookie, no signing.
//   - New: getRoomPlayInfo with qn=0 (Pure Live's _play passes
//     qn ?? 0) + protocol=0,1 + format=0,1,2 + codec=0 + dolby=5 +
//     panorama=1, so the server returns EVERY qn it serves. Each qn
//     becomes one quality {id, name, bitrate, urls: [...]} where urls
//     are ALL CDN lines for that qn (url_info[].host + base_url +
//     extra), ordered exactly like Pure Live's _compareCandidates:
//     http_stream before http_hls, flv < ts < fmp4, avc first, mcdn
//     hosts last, then URL. Quality names come from the existing
//     DIRECT_BILI_QNAME map via directBiliQName (流畅/高清/超清/蓝光/
//     原画/2K/4K/杜比) — no new names invented.
//   - GUEST DOWNGRADE (verified live 2026-11-16): the response lists
//     accept_qn [10000, 400, 250] but every codec's current_qn is
//     250, and re-asking with qn=10000 or qn=400 still delivers 250
//     — Pure Live's own note ("guests asking 10000 get 250"). So the
//     qualities list contains ONLY qns with playable URLs in this
//     response (the delivered tier), NOT the full accept_qn union
//     Pure Live lists for logged-in users. The sheet therefore shows
//     only what a guest can actually play — no dead 原画/蓝光 buttons.
//     directBiliPlay(roomId, qid) still forwards a requested qn when
//     given (Pure Live's _play(qn)), so IF a room ever delivers a
//     higher tier on explicit ask, quality switching works; the
//     coordinator must pass qid through directLivePlay for Bili
//     (app.js line ~1801: `return directBiliPlay(room);` ->
//     `return directBiliPlay(room, qid);`).
//   - The top-level {url, type, quality} compat fields are kept:
//     url = urls[0] of the BEST quality, type = 'flv' if that URL is
//     an FLV stream else 'hls', quality = the best qn as a string.
//     Callers (liveCurUrls / liveLines / liveNativeQualities) already
//     read qualities[].urls, so quality + line switching work with no
//     other change.
//   - Guest buvid3/buvid4 cookie (BilibiliApi.buvid + cookie, from
//     api.bilibili.com/x/frontend/finger/spi) is sent on the play
//     request, exactly like Pure Live's _play. No login cookie exists
//     in this app, so the guest pair IS the cookie.
//   - WBI signing (mixinKey + wbiQuery + wbiSign) is implemented and
//     used by directBiliDanmakuArgs for the SIGNED getDanmuInfo call
//     (Pure Live's danmakuArgs: up to 4 attempts, WBI keys renewed on
//     attempts 2 and 4, 180ms x attempt between tries). getRoomPlayInfo
//     itself stays UNSIGNED (Pure Live's _play is unsigned too —
//     only the cookie); signing is only for getDanmuInfo.
//   - Bitrates are NOMINAL display values (Bilibili does not return a
//     bitrate per qn in this API); the quality sheet shows them as
//     "· x Mbps" only, never for any switching decision.
//   - codec=0 (avc) only, per the port spec. HEVC-only tiers (some
//     4K/杜比 streams) will not appear; add codec=1 if that is ever
//     needed — the candidate parser already handles any codec_name.
//
// DANMAKU INTEGRATION (coordinator): startBiliDanmu in app.js still
// calls the UNSIGNED getConf endpoint. To use the signed path, call
// directBiliDanmakuArgs(roomId) first; on success it returns
// {roomId, uid: 0, token, servers, buvid, headers} — pass token +
// servers[0]'s host to BiliDanmuClient the same way getConf's
// {token, host} is passed today. On null (all 4 attempts failed),
// keep the existing getConf fallback. The danmaku WebSocket itself
// is unchanged (BiliDanmuClient already connects directly).
//
// NOTE ON MIXED FORMATS: one quality's urls[] mixes FLV (http_stream)
// and HLS (http_hls, ts/fmp4) lines, in Pure Live's order. The native
// player (ijkplayer) plays both, so in the App this is fine. The
// in-page web player routes on the TOP-LEVEL type only and would try
// every line with the same engine — but the direct path only runs when
// nativeFetch exists, i.e. inside the App, where the native branch
// takes the URL before any web decoding happens.

// WBI mixin permutation table (BilibiliApi._mixinTable).
var BILI_LL_MIXIN_TABLE = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12,
  38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62,
  11, 36, 20, 34, 44, 52
];
// Nominal display bitrates in kbps per qn (Bilibili returns no bitrate;
// these are approximate, shown as "· x Mbps" only).
var BILI_LL_QN_BITRATE = { 80: 800, 150: 1300, 250: 2500, 400: 4000, 10000: 8000, 15000: 12000, 20000: 16000, 30000: 18000 };
// General danmaku gateway, tried first (BilibiliApi.danmakuGateway).
var BILI_LL_DANMAKU_GATEWAY = 'wss://broadcastlv.chat.bilibili.com/sub';
// WBI keys + guest buvid cache (BilibiliSite._Session, 6h lifetime).
var BILI_LL_SESSION = { buvid3: '', buvid4: '', imgKey: '', subKey: '', keysAt: 0, buvidFetch: null, keysFetch: null };
var BILI_LL_SESSION_TTL_MS = 6 * 60 * 60 * 1000;
var BILI_LL_RETRY_DELAY_MS = 180;

function biliLlIsHttp(u){ return /^https?:\/\//i.test(u || ''); }
function biliLlFormatRank(f){
  if (f === 'flv') return 0;
  if (f === 'ts') return 1;
  if (f === 'fmp4') return 2;
  return 3;
}
// Port of BilibiliApi._compareCandidates. requestedQn is the qn the
// request asked for (0 here: no candidate matches, so that tier is a
// no-op and ordering falls through to protocol/format/codec).
function biliLlCompareCandidates(a, b, requestedQn){
  var byReq = ((a.qn === requestedQn) ? 0 : 1) - ((b.qn === requestedQn) ? 0 : 1);
  if (byReq) return byReq;
  var byProto = ((a.protocol === 'http_stream') ? 0 : 1) - ((b.protocol === 'http_stream') ? 0 : 1);
  if (byProto) return byProto;
  var byFmt = biliLlFormatRank(a.format) - biliLlFormatRank(b.format);
  if (byFmt) return byFmt;
  var byCodec = ((a.codec === 'avc') ? 0 : 1) - ((b.codec === 'avc') ? 0 : 1);
  if (byCodec) return byCodec;
  var byEdge = ((a.url.indexOf('mcdn') >= 0) ? 1 : 0) - ((b.url.indexOf('mcdn') >= 0) ? 1 : 0);
  if (byEdge) return byEdge;
  return a.url < b.url ? -1 : (a.url > b.url ? 1 : 0);
}
// Port of BilibiliApi._qnNames: g_qn_desc qn -> desc.
function biliLlQnNames(playurl){
  var names = {};
  var list = (playurl && playurl.g_qn_desc) || [];
  for (var i = 0; i < list.length; i++) {
    var m = list[i] || {};
    var qn = Number(m.qn);
    if (qn > 0 && typeof m.desc === 'string' && m.desc) names[qn] = m.desc;
  }
  return names;
}
// Port of BilibiliApi._codecs: flatten stream[].format[].codec[] into
// {protocol, format, codec} entries.
function biliLlCodecs(playurl){
  var out = [];
  var streams = (playurl && playurl.stream) || [];
  for (var i = 0; i < streams.length; i++) {
    var st = streams[i] || {};
    var protocol = (typeof st.protocol_name === 'string') ? st.protocol_name : '';
    var formats = st.format || [];
    for (var j = 0; j < formats.length; j++) {
      var fm = formats[j] || {};
      var name = (typeof fm.format_name === 'string') ? fm.format_name : '';
      var codecs = fm.codec || [];
      for (var k = 0; k < codecs.length; k++) {
        if (codecs[k] && typeof codecs[k] === 'object') out.push({ protocol: protocol, format: name, codec: codecs[k] });
      }
    }
  }
  return out;
}
// Port of BilibiliApi.mixinKey: imgKey + subKey permuted by the fixed
// table, first 32 characters.
function biliLlMixinKey(imgKey, subKey){
  var origin = String(imgKey || '') + String(subKey || '');
  if (origin.length < 64) throw new Error('WBI keys too short (' + origin.length + ' chars)');
  var out = '';
  for (var i = 0; i < BILI_LL_MIXIN_TABLE.length; i++) out += origin.charAt(BILI_LL_MIXIN_TABLE[i]);
  return out.substring(0, 32);
}
// Port of BilibiliApi.wbiQuery: params + wts, sorted by key, [!'()*]
// stripped from values, percent-encoded like encodeURIComponent.
// The caller appends '&w_rid=' + md5(query + mixinKey).
function biliLlWbiQuery(params, wts){
  var all = {};
  var k;
  for (k in params) { if (Object.prototype.hasOwnProperty.call(params, k)) all[k] = params[k]; }
  all.wts = String(wts);
  var keys = Object.keys(all).sort();
  var parts = [];
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i];
    var val = String(all[key]).replace(/[!'()*]/g, '');
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(val));
  }
  return parts.join('&');
}
// Port of BilibiliSite.wbiSign.
function biliLlWbiSign(params, imgKey, subKey, wts){
  var query = biliLlWbiQuery(params, wts);
  return query + '&w_rid=' + directMd5(query + biliLlMixinKey(imgKey, subKey));
}
// Port of BilibiliApi.buvid + cookie (guest only: this app has no login
// cookie, so the guest pair IS the cookie).
function biliLlCookieString(){
  if (!BILI_LL_SESSION.buvid3) return '';
  return 'buvid3=' + BILI_LL_SESSION.buvid3 + ';buvid4=' + (BILI_LL_SESSION.buvid4 || '') + ';';
}
// Port of BilibiliSite._buvid: finger/spi, requested once for
// concurrent callers; a failure clears the cache so the next request
// tries again.
function biliLlBuvid(){
  if (BILI_LL_SESSION.buvid3) return Promise.resolve({ buvid3: BILI_LL_SESSION.buvid3, buvid4: BILI_LL_SESSION.buvid4 });
  if (BILI_LL_SESSION.buvidFetch) return BILI_LL_SESSION.buvidFetch;
  var p = nativeJson('https://api.bilibili.com/x/frontend/finger/spi', { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.bilibili.com/' } }, 10000).then(function(j){
    var d = (j && j.data) || {};
    var b3 = (typeof d.b_3 === 'string') ? d.b_3 : '';
    if (!b3) throw new Error('finger/spi: no b_3');
    BILI_LL_SESSION.buvid3 = b3;
    BILI_LL_SESSION.buvid4 = (typeof d.b_4 === 'string') ? d.b_4 : '';
    return { buvid3: b3, buvid4: BILI_LL_SESSION.buvid4 };
  }).catch(function(e){ BILI_LL_SESSION.buvidFetch = null; throw e; });
  BILI_LL_SESSION.buvidFetch = p;
  return p;
}
// Port of BilibiliApi.apiHeaders.
function biliLlApiHeaders(cookie){
  var h = { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.bilibili.com/' };
  if (cookie) h.Cookie = cookie;
  return h;
}
// Port of BilibiliSite._keys + _cookie: WBI keys from nav, reused 6h.
function biliLlKeys(renew){
  var now = Date.now();
  if (!renew && BILI_LL_SESSION.imgKey && (now - BILI_LL_SESSION.keysAt) < BILI_LL_SESSION_TTL_MS) {
    return Promise.resolve({ imgKey: BILI_LL_SESSION.imgKey, subKey: BILI_LL_SESSION.subKey });
  }
  if (BILI_LL_SESSION.keysFetch) return BILI_LL_SESSION.keysFetch;
  var p = biliLlBuvid().catch(function(){ return null; }).then(function(){
    return nativeJson('https://api.bilibili.com/x/web-interface/nav', { headers: biliLlApiHeaders(biliLlCookieString()) }, 10000);
  }).then(function(j){
    var img = ((j && j.data && j.data.wbi_img) || {});
    function keyOf(u){
      if (typeof u !== 'string' || !u) return '';
      var name = u.substring(u.lastIndexOf('/') + 1).split('.')[0];
      return name || '';
    }
    var imgKey = keyOf(img.img_url);
    var subKey = keyOf(img.sub_url);
    if (!imgKey || !subKey) throw new Error('nav: no wbi_img keys');
    BILI_LL_SESSION.imgKey = imgKey;
    BILI_LL_SESSION.subKey = subKey;
    BILI_LL_SESSION.keysAt = Date.now();
    return { imgKey: imgKey, subKey: subKey };
  }).catch(function(e){ BILI_LL_SESSION.keysFetch = null; throw e; });
  BILI_LL_SESSION.keysFetch = p;
  return p;
}
// Port of BilibiliSite._signed (without the w_webid leg: getDanmuInfo
// does not need it). A -352 answer renews keys + guest buvid and
// retries once after 180ms; a second -352 throws.
function biliLlSignedGet(path, params){
  function attempt(renew){
    return biliLlKeys(renew).then(function(keys){
      return biliLlBuvid().catch(function(){ return null; }).then(function(){
        var cookie = biliLlCookieString();
        var wts = Math.floor(Date.now() / 1000);
        var query = biliLlWbiSign(params, keys.imgKey, keys.subKey, wts);
        return nativeJson('https://api.live.bilibili.com' + path + '?' + query, { headers: biliLlApiHeaders(cookie) }, 10000).then(function(j){
          if (j && j.code === -352) {
            if (renew) { var e = new Error('risk control (-352)'); e.code = -352; throw e; }
            BILI_LL_SESSION.buvid3 = '';
            BILI_LL_SESSION.buvid4 = '';
            BILI_LL_SESSION.buvidFetch = null;
            return new Promise(function(res){ setTimeout(res, BILI_LL_RETRY_DELAY_MS); }).then(function(){ return attempt(true); });
          }
          return j;
        });
      });
    });
  }
  return attempt(false);
}
// Port of BilibiliApi.danmakuInfo: token + servers (general gateway
// first, then host_list wss nodes, 443 omitted, deduped).
function biliLlDanmakuInfo(j){
  var d = (j && j.data) || {};
  var token = (typeof d.token === 'string') ? d.token : '';
  if (!token) throw new Error('getDanmuInfo: empty token');
  var servers = [BILI_LL_DANMAKU_GATEWAY];
  var list = d.host_list || [];
  for (var i = 0; i < list.length; i++) {
    var host = list[i] && list[i].host;
    if (typeof host !== 'string' || !host) continue;
    var port = Number(list[i].wss_port) || 443;
    var ep = 'wss://' + host + (port === 443 ? '' : ':' + port) + '/sub';
    if (servers.indexOf(ep) < 0) servers.push(ep);
  }
  return { token: token, servers: servers };
}
// Port of BilibiliSite.danmakuArgs: SIGNED getDanmuInfo, up to 4
// attempts, WBI keys renewed on attempts 2 and 4 (index 1 and 3),
// 180ms x attempt between tries. Returns null when every attempt
// fails (caller keeps the old unsigned getConf fallback) instead of
// throwing, so a danmaku failure never breaks room entry.
// NOT wired into startBiliDanmu yet — see the header note.
async function directBiliDanmakuArgs(roomId){
  var longId = String(roomId || '').trim();
  if (!/^\d+$/.test(longId)) return null;
  var lastErr = null;
  for (var attempt = 0; attempt < 4; attempt++) {
    if (attempt === 1 || attempt === 3) { BILI_LL_SESSION.imgKey = ''; BILI_LL_SESSION.subKey = ''; BILI_LL_SESSION.keysFetch = null; }
    try {
      var j = await biliLlSignedGet('/xlive/web-room/v1/index/getDanmuInfo', { id: longId, type: '0' });
      if (!j || j.code !== 0) throw new Error('getDanmuInfo: code ' + (j && j.code));
      var info = biliLlDanmakuInfo(j);
      var cookie = biliLlCookieString();
      var headers = { 'User-Agent': DIRECT_LIVE_UA, 'Origin': 'https://live.bilibili.com', 'Referer': 'https://live.bilibili.com/' + longId };
      if (cookie) headers.Cookie = cookie;
      return { roomId: Number(longId), uid: 0, token: info.token, servers: info.servers, buvid: BILI_LL_SESSION.buvid3 || '', headers: headers };
    } catch (e) { lastErr = e; }
    if (attempt < 3) await new Promise(function(r){ setTimeout(r, BILI_LL_RETRY_DELAY_MS * (attempt + 1)); });
  }
  return null;
}
// Port of BilibiliApi.qualities + resolution, in one request:
// getRoomPlayInfo at qn=0 (or the requested qid) returns the qn(s)
// the server actually delivers; each delivered qn's candidates are
// grouped into one quality with ALL its CDN lines (urls[]).
// Overrides directBiliPlay in app.js (loaded after it).
async function directBiliPlay(roomId, qid){
  var id = String(roomId || '').trim();
  if (!id) return null;
  var askedQn = Number(qid);
  if (!(askedQn > 0)) askedQn = 0;
  var cookie = '';
  try { await biliLlBuvid(); cookie = biliLlCookieString(); } catch (e) { cookie = ''; }
  var headers = { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.bilibili.com/' + encodeURIComponent(id), 'Origin': 'https://live.bilibili.com' };
  if (cookie) headers.Cookie = cookie;
  // Pure Live _play: protocol 0,1 + format 0,1,2 + codec 0 + qn (0 =
  // all / server default, else the requested tier) + platform web +
  // ptype 8 + dolby 5 + panorama 1 + mask 0 + no_playurl 0.
  var j = await nativeJson('https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=' + encodeURIComponent(id) + '&protocol=0,1&format=0,1,2&codec=0&qn=' + askedQn + '&platform=web&ptype=8&dolby=5&panorama=1&mask=0&no_playurl=0', { headers: headers }, 12000);
  if (!j || j.code !== 0 || !j.data) return null;
  var data = j.data;
  // playurl_info null = offline / carousel without a stream for guests /
  // paid broadcast without a ticket (BilibiliApi.playData).
  var playurl = ((data.playurl_info || {}).playurl) || null;
  if (!playurl) return null;
  var names = biliLlQnNames(playurl);
  // Build every candidate URL: host + base_url + extra, per codec.
  var candidates = [];
  var entries = biliLlCodecs(playurl);
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i];
    var codec = entry.codec;
    if (typeof codec.base_url !== 'string' || !codec.base_url) continue;
    var currentQn = Number(codec.current_qn);
    if (!(currentQn > 0)) continue;
    var codecName = (typeof codec.codec_name === 'string') ? codec.codec_name.toLowerCase() : '';
    var infos = codec.url_info || [];
    for (var k = 0; k < infos.length; k++) {
      var info = infos[k] || {};
      var host = (typeof info.host === 'string') ? info.host.trim() : '';
      var extra = (typeof info.extra === 'string') ? info.extra.trim() : '';
      var url = directLiveToHttps(host) + codec.base_url + extra;
      if (!biliLlIsHttp(url)) continue;
      try { if (!new URL(url).host) continue; } catch (e) { continue; }
      candidates.push({ url: url, qn: currentQn, protocol: entry.protocol, format: entry.format, codec: codecName });
    }
  }
  if (!candidates.length) return null;
  candidates.sort(function(a, b){ return biliLlCompareCandidates(a, b, 0); });
  // Group by qn (best first). A qn listed in accept_qn but served by no
  // codec in this response gets no entry — it has no playable URL here.
  var byQn = {};
  var qns = [];
  for (var c = 0; c < candidates.length; c++) {
    var cand = candidates[c];
    if (!byQn[cand.qn]) { byQn[cand.qn] = []; qns.push(cand.qn); }
    byQn[cand.qn].push(cand.url);
  }
  qns.sort(function(a, b){ return b - a; });
  var qualities = [];
  for (var q = 0; q < qns.length; q++) {
    var qn = qns[q];
    var urls = [];
    var seen = {};
    var list = byQn[qn];
    for (var u = 0; u < list.length; u++) { if (!seen[list[u]]) { seen[list[u]] = true; urls.push(list[u]); } }
    if (!urls.length) continue;
    qualities.push({ id: String(qn), name: directBiliQName(qn), bitrate: BILI_LL_QN_BITRATE[qn] || 0, urls: urls });
  }
  if (!qualities.length) return null;
  var best = qualities[0];
  var bestUrl = best.urls[0];
  var isFlv = /\.flv(\?|$)/i.test(bestUrl);
  return { url: bestUrl, type: isFlv ? 'flv' : 'hls', quality: String(best.id), qualities: qualities };
}

// ---- API hosts used by this file (nativeFetch allowlist) ----
// Already allowlisted (verified in ios/HAoStudio/ViewController.swift):
//   api.live.bilibili.com  — getRoomPlayInfo, getDanmuInfo
//   api.bilibili.com       — x/frontend/finger/spi (buvid), x/web-interface/nav (WBI keys)
// No NEW nativeFetch host is needed.
// Media hosts (played by the native player directly, NOT via
// nativeFetch — listed here only so the allowlist review can see them):
//   *.bilivideo.com (e.g. cn-gotcha*.bilivideo.com, d1--cn-gotcha*.bilivideo.com)
// Danmaku WebSocket hosts (direct WebSocket, NOT nativeFetch):
//   broadcastlv.chat.bilibili.com, *.chat.bilibili.com

// ---- Douyu live lines (Pure Live port) — live-lines-douyu.js ----
// Port of Pure Live `packages/live_core/lib/src/sites/douyu/`:
//   DouyuSite.resolvePlayUrlsRaw / resolvePlayUrlsForRecoveryRaw /
//   getPlayQualities (guest fallback) / getPlayUrlRefreshAt /
//   getPlayUrlInvalidAt / _leaseOf  (douyu_site.dart)
//   DouyuApi.qualities / cdns / mediaUrl / resolution / lease /
//   statedLifetime / signedForm / descriptor  (douyu_api.dart)
//
// LOAD ORDER: this file loads AFTER app.js, so the `function`
// declarations below override the single-URL versions in app.js.
// Only `function` declarations are used here (no const/let at top
// level, so no app.js name can be redefined); every new name carries
// the DOUYU_LL_ prefix.
//
// WHAT CHANGED vs the old directDouyuPlay in app.js:
//   - Old: ONE getH5PlayV1 call (cdn='', one rate) -> one URL; the
//     `qualities` list had no urls at all.
//   - New: metadata call (rate=-1, cdn='') gives multirates +
//     cdnsWithName; EVERY CDN is signed separately at EVERY rate
//     (one _answer per CDN + rate, exactly like resolvePlayUrlsRaw),
//     so each quality returns {id, name, bitrate, urls: [...]} with
//     one signed URL per CDN line. The caller (liveCurUrls /
//     liveLines in app.js) already reads q.urls, so line switching
//     works with no other change.
//   - Lease tracking (DouyuApi.lease): every signed URL records
//     refreshAt / invalidAt (ms timestamps) in DOUYU_LL_LEASES and
//     on the returned object. Refresh before refreshAt; never open
//     a new connection at/after invalidAt — re-fetch fresh metadata
//     instead (directDouyuPlayForRecovery). The old
//     `expire=300 & fcdn=ws -> expire=0` compat hack is kept per URL.
//   - Guest fallback: this app has NO account system, so every
//     request is ALREADY the guest path — directDyuCookie() sends
//     only dy_did/acf_did (a 32-hex device id, cf. DouyuApi.
//     generateDeviceId), never acf_auth/acf_jwt_token/dy_auth.
//     Pure Live's getPlayQualities guest fallback only matters when
//     a saved login is refused; with no login there is nothing to
//     fall back from, so the guest request IS the primary request.
//     (Verified: no login cookie is sent anywhere in app.js.)
//   - Recovery: directDouyuPlayForRecovery() re-fetches fresh
//     metadata first and never reuses an old URL (port of
//     resolvePlayUrlsForRecoveryRaw).
//
// INTEGRATION (coordinator): add
//   <script src="./live-lines-douyu.js"></script>
// AFTER app.js in web/index.html. Nothing else in app.js needs to
// change: directLivePlay('douyu',...) calls directDouyuPlay, and
// liveCurUrls()/liveLines() already consume qualities[].urls.
// The nativeFetch allowlist needs no new host for THIS file (same
// www.douyu.com endpoints as before) — see the host list at the end.

// Lease constants (DouyuApi.leaseLead / forcedLeaseLifetime /
// descriptorMargin / descriptorLifetime).
var DOUYU_LL_LEASE_LEAD_S = 45;
var DOUYU_LL_FORCED_LEASE_S = 300;
// Forced renewal ON (Pure Live's `douyuForceRenewal`, upgrade 2-1):
// live signed URLs in practice carry NO expire= param at all
// (verified in the smoke test — wsAuth/token URLs, no expire=), so
// without this there would be no lease to track. An FLV URL that
// states no lifetime is therefore treated as a 5-min lease
// (DouyuApi.forcedLeaseLifetime); refresh at ~4m15s, never open a
// new connection after 5 min — re-fetch fresh metadata instead.
// A URL that DOES state expire= keeps its stated lifetime.
var DOUYU_LL_FORCE_RENEWAL = true;
var DOUYU_LL_DESCRIPTOR_MARGIN_S = 30;
var DOUYU_LL_DESCRIPTOR_TTL_MS = 5 * 60 * 1000;
// url -> {refreshAt, invalidAt} (ms since epoch), capped at 64 entries.
var DOUYU_LL_LEASES = {};
// Cached signing descriptor: {did, key, randStr, encData, encTime,
// isSpecial, expireAtMs, fetchedAtMs} (DouyuSite._descriptor, 5 min).
var DOUYU_LL_DESC_CACHE = null;

// HTML-entity decode for media URLs (DouyuApi.mediaUrl decodes entities).
function DOUYU_LL_decodeEnt(s) {
  return String(s || '').replace(/&#(\d+);/g, function (m, n) {
    try { return String.fromCodePoint(Number(n)); } catch (e) { return m; }
  }).replace(/&amp;/g, '&');
}

// _playable: parseable URL with an http/https/rtmp scheme and a host.
function DOUYU_LL_playable(value) {
  if (!value) return false;
  try {
    var u = new URL(value);
    return !!u.host && (u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'rtmp:');
  } catch (e) { return false; }
}

// Port of DouyuApi.mediaUrl: absolute rtmp_live wins; else rtmp_url
// (then flv_url) joined with rtmp_live; else player_1 / stream_url /
// url; else an flv_url ending .flv/.m3u8/.mp4. A bare CDN base is
// never media. Returns '' when nothing is playable.
function DOUYU_LL_mediaUrl(data) {
  function field(k) { return DOUYU_LL_decodeEnt(data[k]); }
  var live = field('rtmp_live');
  if (DOUYU_LL_playable(live)) return live;
  var keys = ['rtmp_url', 'flv_url'];
  for (var i = 0; i < keys.length; i++) {
    var base = field(keys[i]);
    if (!base || !live) continue;
    var joined = base.replace(/\/+$/, '') + '/' + live.replace(/^\/+/, '');
    if (DOUYU_LL_playable(joined)) return joined;
  }
  var fallbacks = ['player_1', 'stream_url', 'url'];
  for (var j = 0; j < fallbacks.length; j++) {
    var v = field(fallbacks[j]);
    if (DOUYU_LL_playable(v)) return v;
  }
  var flv = field('flv_url');
  var path = '';
  try { path = new URL(flv).pathname.toLowerCase(); } catch (e) {}
  if (DOUYU_LL_playable(flv) && (path.slice(-4) === '.flv' || path.slice(-5) === '.m3u8' || path.slice(-4) === '.mp4')) return flv;
  return '';
}

// Port of DouyuApi.cdns: cdnsWithName in order, deduped; the answering
// rtmp_cdn first when missing; scdn* codes last; [''] (server picks)
// when there are none. A line's identity is its code, never its index.
function DOUYU_LL_cdns(data) {
  var codes = [];
  var items = data.cdnsWithName || [];
  for (var i = 0; i < items.length; i++) {
    var c = items[i] && items[i].cdn;
    if (c && codes.indexOf(c) < 0) codes.push(String(c));
  }
  var cur = data.rtmp_cdn;
  if (cur && codes.indexOf(String(cur)) < 0) codes.unshift(String(cur));
  if (!codes.length) return [''];
  var head = codes.filter(function (x) { return x.indexOf('scdn') !== 0; });
  var tail = codes.filter(function (x) { return x.indexOf('scdn') === 0; });
  return head.concat(tail);
}

// Display name per CDN code, from cdnsWithName when the answer names it.
function DOUYU_LL_cdnNames(data) {
  var names = {};
  var items = data.cdnsWithName || [];
  for (var i = 0; i < items.length; i++) {
    if (items[i] && items[i].cdn && items[i].name) names[String(items[i].cdn)] = String(items[i].name);
  }
  return names;
}

// Port of DouyuApi.qualities: multirates in PLATFORM order (never
// sorted: rate is a request code, not a bitrate), first of a rate
// wins. streamStatus 0 = room on air but no stream pushed ->
// StreamUnavailable (a retry cannot fix it). Without multirates,
// one "默认" option for data.rate.
// Returns [{rate (number), id (string), name, bitrate, cdns: [...]}].
function DOUYU_LL_qualities(data) {
  if (Number(data.streamStatus) === 0) {
    throw new Error('douyu: streamStatus 0 (no stream pushed)');
  }
  var lines = DOUYU_LL_cdns(data);
  var seen = {};
  var out = [];
  var items = data.multirates || [];
  for (var i = 0; i < items.length; i++) {
    var rate = Number(items[i] && items[i].rate);
    if (!isFinite(rate) || seen[rate]) continue;
    seen[rate] = true;
    out.push({
      rate: rate,
      id: String(rate),
      name: (items[i] && items[i].name) || ('画质' + rate),
      bitrate: directLiveNum(items[i] && items[i].bit),
      cdns: lines.slice()
    });
  }
  if (out.length) return out;
  var fallbackRate = isFinite(Number(data.rate)) ? Number(data.rate) : -1;
  return [{ rate: fallbackRate, id: String(fallbackRate), name: '默认', bitrate: 0, cdns: lines }];
}

// Port of DouyuApi.confirmedRate: the rate the server delivered
// (integer >= 0); anything else is unconfirmed (null), never
// truncated into source quality.
function DOUYU_LL_confirmedRate(data) {
  var r = Number(data.rate);
  return (isFinite(r) && Math.floor(r) === r && r >= 0) ? r : null;
}

// Port of DouyuApi.statedLifetime: the `expire` seconds a media URL
// states (first expire= param); null for expire=0 or none.
function DOUYU_LL_statedLifetimeS(url) {
  var m = String(url || '').match(/(?:^|[?&])expire=(\d+)(?:&|$)/);
  if (!m) return null;
  var s = Number(m[1]);
  return s > 0 ? s : null;
}

// Port of DouyuApi.lease: lifetime = stated, else (forceRenewal and
// .flv) 5 min; expiresAt = issuedAt + lifetime; refreshAt =
// expiresAt - min(45s, lifetime/4). Returns {refreshAt, invalidAt}
// in ms, or null when the URL states no lifetime.
function DOUYU_LL_lease(url, issuedAtMs, forceRenewal) {
  var lifetime = DOUYU_LL_statedLifetimeS(url);
  if (lifetime === null && forceRenewal) {
    var path = '';
    try { path = new URL(url).pathname.toLowerCase(); } catch (e) {}
    if (path.slice(-4) === '.flv') lifetime = DOUYU_LL_FORCED_LEASE_S;
  }
  if (lifetime === null) return null;
  var expiresAt = issuedAtMs + lifetime * 1000;
  var lead = Math.min(DOUYU_LL_LEASE_LEAD_S, Math.floor(lifetime / 4));
  return { refreshAt: expiresAt - lead * 1000, invalidAt: expiresAt };
}

function DOUYU_LL_recordLease(url, issuedAtMs) {
  var lease = DOUYU_LL_lease(url, issuedAtMs, DOUYU_LL_FORCE_RENEWAL);
  if (!lease) return null;
  DOUYU_LL_LEASES[url] = lease;
  var keys = Object.keys(DOUYU_LL_LEASES);
  if (keys.length > 64) delete DOUYU_LL_LEASES[keys[0]];
  return lease;
}

// Port of DouyuApi.descriptor + DouyuSite._descriptorFor (cache):
// fetch getEncryption for this did, reuse while younger than 5 min
// and usable (expire_at more than 30s out). Throws when incomplete.
async function DOUYU_LL_descriptor(did) {
  var now = Date.now();
  var c = DOUYU_LL_DESC_CACHE;
  if (c && c.did === did && now - c.fetchedAtMs < DOUYU_LL_DESCRIPTOR_TTL_MS &&
      c.expireAtMs - now > DOUYU_LL_DESCRIPTOR_MARGIN_S * 1000) return c;
  var enc = await nativeJson('https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption?did=' + did, {
    headers: { 'User-Agent': DIRECT_LIVE_UA, 'Cookie': directDyuCookie() }
  }, 12000);
  var d = (enc && enc.data) || {};
  if (!d.key || !d.rand_str || !d.enc_data || !(Number(d.enc_time) >= 1) || !d.expire_at) {
    throw new Error('douyu: getEncryption descriptor incomplete');
  }
  var desc = {
    did: did, key: String(d.key), randStr: String(d.rand_str), encData: String(d.enc_data),
    encTime: Number(d.enc_time), isSpecial: Number(d.is_special) === 1,
    expireAtMs: Number(d.expire_at) * 1000, fetchedAtMs: now
  };
  if (desc.expireAtMs - Date.now() <= DOUYU_LL_DESCRIPTOR_MARGIN_S * 1000) {
    throw new Error('douyu: getEncryption descriptor expired');
  }
  DOUYU_LL_DESC_CACHE = desc;
  return desc;
}

// Port of DouyuDescriptor.auth: rand_str hashed with the key encTime
// times, then md5 of secret + key + rid + tt (without rid and tt
// when isSpecial).
function DOUYU_LL_auth(desc, roomId, tt) {
  var secret = desc.randStr;
  for (var i = 0; i < desc.encTime; i++) secret = directMd5(secret + desc.key);
  var salt = desc.isSpecial ? '' : (String(roomId) + tt);
  return directMd5(secret + desc.key + salt);
}

// One signed getH5PlayV1 for (rate, cdn). Port of DouyuSite._play
// (single attempt) + DouyuApi.playData: HTTP 403 = the edge refusing
// the client; error != 0 (-5 = room not live) is StreamUnavailable
// and is NOT retried; no data = ApiChanged.
async function DOUYU_LL_playOnce(roomId, did, desc, tt, rate, cdn) {
  var b = new URLSearchParams({
    enc_data: desc.encData, tt: String(tt), did: did,
    auth: DOUYU_LL_auth(desc, roomId, tt), cdn: cdn, rate: String(rate),
    hevc: '0', fa: '0', ive: '0', ver: 'Douyu_new', iar: '0'
  });
  var rr = await nativeFetch('https://www.douyu.com/lapi/live/getH5PlayV1/' + encodeURIComponent(roomId), {
    method: 'POST',
    headers: {
      'User-Agent': DIRECT_LIVE_UA,
      'Referer': 'https://www.douyu.com/' + encodeURIComponent(roomId),
      'Origin': 'https://www.douyu.com',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': directDyuCookie()
    },
    body: b.toString(), timeout: 15000
  });
  if (rr.status === 403) throw new Error('douyu: getH5PlayV1 HTTP 403 (edge refused)');
  if (rr.status < 200 || rr.status >= 300) throw new Error('douyu: getH5PlayV1 http ' + rr.status);
  var jj = JSON.parse(rr.text);
  if (Number(jj.error) !== 0 || !jj.data) {
    throw new Error('douyu play failed: ' + (jj.msg || rr.status));
  }
  return jj.data;
}

// Port of DouyuApi.answer: one CDN's signed answer as a line —
// media URL + confirmed rate + lease. The old `expire=300 &
// fcdn=ws -> expire=0` compat hack is kept per URL (the lease is
// read from the FIRST expire= param, which stays 300, so the hack
// does not shorten the tracked lifetime).
function DOUYU_LL_answer(data, roomId, cdn, issuedAtMs) {
  var url = DOUYU_LL_mediaUrl(data);
  if (!url) throw new Error('douyu: getH5PlayV1 no playable URL');
  url = directLiveToHttps(url);
  if (url.indexOf('expire=300') >= 0 && url.indexOf('fcdn=ws') >= 0) url += '&expire=0';
  var lease = DOUYU_LL_recordLease(url, issuedAtMs);
  return {
    url: url, cdn: cdn, rate: DOUYU_LL_confirmedRate(data),
    refreshAt: lease ? lease.refreshAt : null,
    invalidAt: lease ? lease.invalidAt : null
  };
}

// Port of DouyuSite.resolvePlayUrlsRaw + DouyuApi.resolution:
// sign EVERY CDN of one quality at its rate (CDNs in parallel; a
// failing CDN is skipped, and only when all fail is the last error
// thrown). CDNs may confirm different rates and one label must never
// cover a mix: the group confirming the requested rate wins, else
// the first confirmed group, else the unconfirmed group.
async function DOUYU_LL_resolveQuality(roomId, did, desc, tt, q, cdnNames) {
  var settled = await Promise.all(q.cdns.map(function (cdn) {
    return DOUYU_LL_playOnce(roomId, did, desc, tt, q.rate, cdn)
      .then(function (data) { return DOUYU_LL_answer(data, roomId, cdn, tt * 1000); })
      .catch(function (e) { return { __error: e }; });
  }));
  var answers = [];
  var lastErr = null;
  settled.forEach(function (a) {
    if (a && a.__error) lastErr = a.__error;
    else if (a) answers.push(a);
  });
  if (!answers.length) throw (lastErr || new Error('douyu: all CDNs failed for rate ' + q.rate));
  var groups = {};
  var order = [];
  answers.forEach(function (a) {
    var k = (a.rate === null || a.rate === undefined) ? 'null' : String(a.rate);
    if (!groups[k]) { groups[k] = []; order.push(k); }
    if (groups[k].every(function (x) { return x.url !== a.url; })) groups[k].push(a);
  });
  var appliedKey = groups[String(q.rate)] ? String(q.rate) : null;
  if (appliedKey === null) {
    for (var i = 0; i < order.length; i++) {
      if (order[i] !== 'null') { appliedKey = order[i]; break; }
    }
  }
  if (appliedKey === null) appliedKey = order[0];
  var lines = groups[appliedKey];
  var urls = lines.map(function (x) { return x.url; });
  var firstLease = lines[0];
  return {
    id: q.id, name: q.name, bitrate: q.bitrate, urls: urls,
    lines: lines.map(function (x) { return { id: x.cdn, name: (cdnNames && cdnNames[x.cdn]) || x.cdn, url: x.url }; }),
    refreshAt: firstLease.refreshAt, invalidAt: firstLease.invalidAt,
    confirmedRate: appliedKey === 'null' ? null : Number(appliedKey),
    unconfirmed: appliedKey === 'null'
  };
}

// Metadata call (rate=-1: the server chooses; the answer carries
// multirates + cdnsWithName). Falls back to rate '2' metadata — the
// old default — if -1 is refused.
async function DOUYU_LL_metadata(roomId, did, desc, tt) {
  try {
    return await DOUYU_LL_playOnce(roomId, did, desc, tt, -1, '');
  } catch (e) {
    return await DOUYU_LL_playOnce(roomId, did, desc, tt, 2, '');
  }
}

// Shared resolve-all path: fresh descriptor + fresh metadata, then
// every quality signed on every CDN. `wantRate` (string/number or
// '') picks the default quality; `firstRate` resolves that quality
// first so recovery fails fast on the one that matters.
async function DOUYU_LL_playAll(roomId, wantRate, firstRate) {
  var did = directDyuDid();
  var desc = await DOUYU_LL_descriptor(did);
  var tt = Math.floor(Date.now() / 1000);
  var meta = await DOUYU_LL_metadata(roomId, did, desc, tt);
  var qs = DOUYU_LL_qualities(meta);
  var cdnNames = DOUYU_LL_cdnNames(meta);
  var ordered = qs.slice();
  if (firstRate !== null && firstRate !== undefined && String(firstRate) !== '') {
    ordered.sort(function (a, b) {
      return (String(a.id) === String(firstRate) ? 0 : 1) - (String(b.id) === String(firstRate) ? 0 : 1);
    });
  }
  var qualities = [];
  var lastErr = null;
  for (var i = 0; i < ordered.length; i++) {
    try {
      qualities.push(await DOUYU_LL_resolveQuality(roomId, did, desc, tt, ordered[i], cdnNames));
    } catch (e) { lastErr = e; }
  }
  if (!qualities.length) throw (lastErr || new Error('douyu: no quality resolved'));
  // Restore platform order for the menu.
  qualities.sort(function (a, b) {
    var ia = -1, ib = -1;
    for (var k = 0; k < qs.length; k++) {
      if (qs[k].id === a.id) ia = k;
      if (qs[k].id === b.id) ib = k;
    }
    return ia - ib;
  });
  var def = null;
  if (wantRate !== undefined && wantRate !== null && String(wantRate) !== '') {
    for (var j = 0; j < qualities.length; j++) {
      if (String(qualities[j].id) === String(wantRate)) { def = qualities[j]; break; }
    }
  }
  if (!def) def = qualities[0];
  var firstUrl = def.urls[0] || '';
  var type = /\.m3u8(\?|$)/i.test(firstUrl) ? 'hls' : 'flv';
  return {
    url: firstUrl, type: type, quality: String(def.id), rate: Number(def.id),
    qualities: qualities,
    refreshAt: def.refreshAt, invalidAt: def.invalidAt
  };
}

// OVERRIDE of app.js directDouyuPlay. Same signature (roomId, rate).
// Returns {url, type, quality, rate, qualities: [{id, name, bitrate,
// urls: [...], lines: [{id, name, url}], refreshAt, invalidAt,
// confirmedRate, unconfirmed}], refreshAt, invalidAt}.
// `url` is urls[0] of the default quality (requested rate when given,
// else the first quality in platform order). All URLs are freshly
// signed in this call — never reused from a previous call.
async function directDouyuPlay(roomId, rate) {
  return DOUYU_LL_playAll(roomId, rate, null);
}

// Port of DouyuSite.resolvePlayUrlsForRecoveryRaw: fresh metadata
// first (the CDN set changes while a connection pauses), then the
// committed rate on the current CDNs; old URLs are never reused.
// Same return shape as directDouyuPlay, with the requested quality
// as the default. Call this (instead of reusing livePlayData.url)
// when a URL is past refreshAt, and always when past invalidAt.
async function directDouyuPlayForRecovery(roomId, qualityId) {
  return DOUYU_LL_playAll(roomId, qualityId, qualityId);
}

// Port of DouyuSite.getPlayUrlRefreshAt: when to fetch a new URL for
// `url` — from the lease its resolution computed, else as if it was
// issued at `nowMs` (default: now). Returns ms since epoch, or null
// when the URL states no lifetime.
function directDouyuPlayRefreshAt(url, nowMs) {
  var known = DOUYU_LL_LEASES[url];
  if (known) return known.refreshAt;
  var lease = DOUYU_LL_lease(url, (nowMs === undefined || nowMs === null) ? Date.now() : nowMs, DOUYU_LL_FORCE_RENEWAL);
  return lease ? lease.refreshAt : null;
}

// Port of DouyuSite.getPlayUrlInvalidAt: the last instant `url` can
// open a new connection (expire after it was issued). Returns ms
// since epoch, or null when the URL states no lifetime.
function directDouyuPlayInvalidAt(url, nowMs) {
  var known = DOUYU_LL_LEASES[url];
  if (known) return known.invalidAt;
  var lease = DOUYU_LL_lease(url, (nowMs === undefined || nowMs === null) ? Date.now() : nowMs, DOUYU_LL_FORCE_RENEWAL);
  return lease ? lease.invalidAt : null;
}

// ---- API hosts used by this platform (for the nativeFetch allowlist) ----
// www.douyu.com        — getEncryption, getH5PlayV1, room lists, categories
// (media hosts are the signed CDN URLs themselves, e.g. *.douyucdn.cn /
// CDN edge hosts returned in rtmp_url — they are playback URLs, not API
// hosts, and are already reached directly by the player, not nativeFetch.)

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

// ---- Douyin live lines (Pure Live port) ----
// Port of Pure Live (packages/live_core/lib/src/sites/douyin/):
//   DouyinSigner (douyin_sign.dart, a_bogus / X-Bogus) + room/web/enter/
//   play path + real search (/aweme/v1/web/live/search/,
//   /aweme/v1/web/general/search/stream/) + partition fallback
//   (douyin_site.dart, douyin_api.dart).
//
// LOAD ORDER: this file loads AFTER app.js and overrides by re-declaring
// the same function names (later function declarations win):
//   directDyRoomPlay, directDyRoomPlayById (overrides)
//   directDySearchLive (new)
// Everything else in this file is prefixed DOUYIN_LL_ and only uses
// function declarations / consts with that prefix, so it cannot clash
// with app.js names. It reuses app.js helpers: nativeJson, nativeText,
// nativeFetch, directDyPrime, directDyPickRoomId, directDyHlsMapGet,
// directDyQualitiesFromMap, directDyUrlFresh, directDyPartitionRoomsByCat,
// directLiveNum, directLiveToHttps, DIRECT_LIVE_UA and the __dy* caches.
//
// INTEGRATION (coordinator):
//   1. index.html: <script src="./live-lines-douyin.js"></script> AFTER app.js.
//   2. directLiveSearch douyin branch: call directDySearchLive(q) instead
//      of the feed substring filter.
//   3. ViewController.swift nativeFetch allowlist: add "www.douyin.com"
//      (live.douyin.com + webcast.amemv.com are already there).
//   4. No server fallback change needed: on any failure these functions
//      return null / [] and the caller falls back as before.
//
// SIGNING NOTES (from douyin_sign.dart):
//   a_bogus = SM3(SM3(query+'cus'))[21,22] + SM3(SM3(body+'cus'))[21,22]
//   + SM3(base64(RC4([0,1,14], UA)))[23,24] + timestamps + options
//   [0,1,14] + aid 6383 + browser fingerprint, laid out in _order,
//   XOR check byte in _checkOrder, stream-ciphered with the 256-byte
//   table, custom base64 (alphabet0). Verified against the vectors in
//   packages/live_core/test/sites/douyin_site_test.dart (SM3 examples,
//   4 a_bogus vectors, 2 signedUrl vectors, X-Bogus vectors) — see the
//   node test in the handoff; all pass offline. Whether the LIVE server
//   accepts the signature is a separate question (smoke test below).

// Douyin web app id / UA (the UA a_bogus encodes; must match the UA the
// requests are sent with — same string as app.js DIRECT_LIVE_UA).
const DOUYIN_LL_AID = 6383;
const DOUYIN_LL_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const DOUYIN_LL_SALT = 'cus';
const DOUYIN_LL_OPTIONS = [0, 1, 14];
const DOUYIN_LL_PAGE_ID = 0;
const DOUYIN_LL_UA_KEY = [0, 1, 14];
const DOUYIN_LL_MSTOKEN_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=';
const DOUYIN_LL_ALPHABET0 = 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
const DOUYIN_LL_ALPHABET1 = 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';
const DOUYIN_LL_XBOGUS_ALPHABET = 'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe';
const DOUYIN_LL_ORDER = [
  18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43, 22, 28, 32, 60, 36, 23,
  29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71
];
const DOUYIN_LL_CHECK_ORDER = [
  18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22, 28, 32, 36, 23, 29, 33, 37, 44, 45, 46, 47,
  48, 49, 50, 24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71
];
const DOUYIN_LL_TABLE = [
  121, 243, 55, 234, 103, 36, 47, 228, 30, 231, 106, 6, 115, 95, 78, 101, 250, 207, 198, 50, 139, 227, 220, 105,
  97, 143, 34, 28, 194, 215, 18, 100, 159, 160, 43, 8, 169, 217, 180, 120, 247, 45, 90, 11, 27, 197, 46, 3,
  84, 72, 5, 68, 62, 56, 221, 75, 144, 79, 73, 161, 178, 81, 64, 187, 134, 117, 186, 118, 16, 241, 130, 71,
  89, 147, 122, 129, 65, 40, 88, 150, 110, 219, 199, 255, 181, 254, 48, 4, 195, 248, 208, 32, 116, 167, 69, 201,
  17, 124, 125, 104, 96, 83, 80, 127, 236, 108, 154, 126, 204, 15, 20, 135, 112, 158, 13, 1, 188, 164, 210, 237,
  222, 98, 212, 77, 253, 42, 170, 202, 26, 22, 29, 182, 251, 10, 173, 152, 58, 138, 54, 141, 185, 33, 157, 31,
  252, 132, 233, 235, 102, 196, 191, 223, 240, 148, 39, 123, 92, 82, 128, 109, 57, 24, 38, 113, 209, 245, 2, 119,
  153, 229, 189, 214, 230, 174, 232, 63, 52, 205, 86, 140, 66, 175, 111, 171, 246, 133, 238, 193, 99, 60, 74, 91,
  225, 51, 76, 37, 145, 211, 166, 151, 213, 206, 0, 200, 244, 176, 218, 44, 184, 172, 49, 216, 93, 168, 53, 21,
  183, 41, 67, 85, 224, 155, 226, 242, 87, 177, 146, 70, 190, 12, 162, 19, 137, 114, 25, 165, 163, 192, 23, 59,
  9, 94, 179, 107, 35, 7, 142, 131, 239, 203, 149, 136, 61, 249, 14, 156
];
const DOUYIN_LL_SM3_IV = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e];
const DOUYIN_LL_Q_NAME = { ORIGION: '原画', ORIGIN: '原画', FULL_HD1: '蓝光', UHD: '蓝光', HD1: '超清', HD: '超清', SD2: '高清', SD: '高清', SD1: '标清', LD: '标清', MD: '流畅' };
const DOUYIN_LL_Q_TIER = { ORIGION: 6000000, ORIGIN: 6000000, FULL_HD1: 5000000, UHD: 5000000, HD1: 4000000, HD: 4000000, SD2: 3000000, SD: 3000000, SD1: 2000000, LD: 2000000, MD: 1000000 };

// ---- byte helpers ----
function DOUYIN_LL_randInt(n){ return Math.floor(Math.random() * n); }
function DOUYIN_LL_utf8(str){
  try { return Array.from(new TextEncoder().encode(String(str))); } catch (e) {
    var s = unescape(encodeURIComponent(String(str))), out = [];
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xff);
    return out;
  }
}
function DOUYIN_LL_utf8Decode(bytes){
  try { return new TextDecoder('utf-8', { fatal: false }).decode(new Uint8Array(bytes)); } catch (e) {
    var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return s;
  }
}
function DOUYIN_LL_enc(s){
  return encodeURIComponent(String(s)).replace(/[!'()*]/g, function(c){ return '%' + c.charCodeAt(0).toString(16).toUpperCase(); });
}

// ---- SM3 (GB/T 32905-2016), 32-byte digest. Port of DouyinSigner._sm3. ----
function DOUYIN_LL_sm3(input){
  var bytes = input;
  function rotl(x, n){ n = n % 32; if (n === 0) return x >>> 0; return ((x << n) | (x >>> (32 - n))) >>> 0; }
  function p0(x){ return (x ^ rotl(x, 9) ^ rotl(x, 17)) >>> 0; }
  function p1(x){ return (x ^ rotl(x, 15) ^ rotl(x, 23)) >>> 0; }
  var msg = bytes.slice();
  var bitLen = bytes.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  var hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
  msg.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255, (lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  var v = DOUYIN_LL_SM3_IV.slice();
  var w = new Array(68), w1 = new Array(64);
  for (var off = 0; off < msg.length; off += 64) {
    for (var j = 0; j < 16; j++) w[j] = ((msg[off + 4 * j] << 24) | (msg[off + 4 * j + 1] << 16) | (msg[off + 4 * j + 2] << 8) | msg[off + 4 * j + 3]) >>> 0;
    for (j = 16; j < 68; j++) w[j] = (p1((w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) >>> 0) ^ rotl(w[j - 13], 7) ^ w[j - 6]) >>> 0;
    for (j = 0; j < 64; j++) w1[j] = (w[j] ^ w[j + 4]) >>> 0;
    var a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7];
    for (j = 0; j < 64; j++) {
      var t = j < 16 ? 0x79cc4519 : 0x7a879d8a;
      var ss1 = rotl(((rotl(a, 12) + e + rotl(t, j)) >>> 0), 7);
      var ss2 = (ss1 ^ rotl(a, 12)) >>> 0;
      var ff = j < 16 ? (a ^ b ^ c) >>> 0 : ((a & b) | (a & c) | (b & c)) >>> 0;
      var gg = j < 16 ? (e ^ f ^ g) >>> 0 : ((e & f) | ((~e) & g)) >>> 0;
      var tt1 = (ff + d + ss2 + w1[j]) >>> 0;
      var tt2 = (gg + h + ss1 + w[j]) >>> 0;
      d = c; c = rotl(b, 9); b = a; a = tt1; h = g; g = rotl(f, 19); f = e; e = p0(tt2);
    }
    v[0] = (v[0] ^ a) >>> 0; v[1] = (v[1] ^ b) >>> 0; v[2] = (v[2] ^ c) >>> 0; v[3] = (v[3] ^ d) >>> 0;
    v[4] = (v[4] ^ e) >>> 0; v[5] = (v[5] ^ f) >>> 0; v[6] = (v[6] ^ g) >>> 0; v[7] = (v[7] ^ h) >>> 0;
  }
  var out = [];
  for (var i = 0; i < 8; i++) out.push((v[i] >>> 24) & 255, (v[i] >>> 16) & 255, (v[i] >>> 8) & 255, v[i] & 255);
  return out;
}

// ---- MD5 over raw bytes (for X-Bogus; directMd5 in app.js only takes a string). ----
function DOUYIN_LL_md5(input){
  var bytes = input.slice();
  var bitLen = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (var i = 0; i < 8; i++) bytes.push((Math.floor(bitLen / Math.pow(2, i * 8))) & 0xff);
  var K = []; for (var k = 0; k < 64; k++) K.push(Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0);
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  function rotl(x, c){ return ((x << c) | (x >>> (32 - c))) >>> 0; }
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (var off = 0; off < bytes.length; off += 64) {
    var M = []; for (var j = 0; j < 16; j++) M.push((bytes[off + j * 4] | (bytes[off + j * 4 + 1] << 8) | (bytes[off + j * 4 + 2] << 16) | (bytes[off + j * 4 + 3] << 24)) >>> 0);
    var A = a0, B = b0, C = c0, D = d0;
    for (var ii = 0; ii < 64; ii++) {
      var F, g;
      if (ii < 16) { F = ((B & C) | (~B & D)) >>> 0; g = ii; }
      else if (ii < 32) { F = ((D & B) | (~D & C)) >>> 0; g = (5 * ii + 1) % 16; }
      else if (ii < 48) { F = (B ^ C ^ D) >>> 0; g = (3 * ii + 5) % 16; }
      else { F = (C ^ (B | ~D)) >>> 0; g = (7 * ii) % 16; }
      F = (F + A + K[ii] + M[g]) >>> 0;
      A = D; D = C; C = B;
      B = (B + rotl(F, S[ii])) >>> 0;
    }
    a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
  }
  var out = [];
  [a0, b0, c0, d0].forEach(function(n){ for (var i = 0; i < 4; i++) out.push((n >>> (i * 8)) & 0xff); });
  return out;
}
function DOUYIN_LL_md5Hex(input){ return DOUYIN_LL_md5(input).map(function(b){ return ('0' + b.toString(16)).slice(-2); }).join(''); }

// ---- RC4. Port of DouyinSigner._rc4. ----
function DOUYIN_LL_rc4(key, data){
  var s = []; for (var i = 0; i < 256; i++) s.push(i);
  var j = 0;
  for (i = 0; i < 256; i++) { j = (j + s[i] + key[i % key.length]) % 256; var tmp = s[i]; s[i] = s[j]; s[j] = tmp; }
  i = 0; j = 0;
  var out = [];
  for (var n = 0; n < data.length; n++) {
    i = (i + 1) % 256; j = (j + s[i]) % 256;
    var t2 = s[i]; s[i] = s[j]; s[j] = t2;
    out.push((data[n] ^ s[(s[i] + s[j]) % 256]) & 0xff);
  }
  return out;
}

// ---- Custom base64. Port of DouyinSigner._encode / _base64. ----
function DOUYIN_LL_encode(bytes){
  var out = '', count = 0;
  for (var i = 0; i < bytes.length; i += 3) {
    var remaining = bytes.length - i;
    var n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0);
    var chars = remaining > 2 ? 4 : remaining + 1;
    for (var j = 0; j < chars; j++) { out += DOUYIN_LL_ALPHABET0[(n >>> (18 - 6 * j)) & 0x3f]; count++; }
  }
  var pad = (4 - count % 4) % 4;
  for (var k = 0; k < pad; k++) out += '=';
  return out;
}
function DOUYIN_LL_base64(bytes, alphabet){
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var remaining = bytes.length - i;
    var n = (bytes[i] << 16) | (remaining > 1 ? bytes[i + 1] << 8 : 0) | (remaining > 2 ? bytes[i + 2] : 0);
    var chars = remaining > 2 ? 4 : remaining + 1;
    for (var j = 0; j < chars; j++) out += alphabet[(n >>> (18 - 6 * j)) & 0x3f];
    if (remaining < 3) for (var k = 0; k < 3 - remaining; k++) out += '=';
  }
  return out;
}

// ---- Stream cipher. Port of DouyinSigner._transform (table copied per call). ----
function DOUYIN_LL_transform(bytes){
  var table = DOUYIN_LL_TABLE.slice();
  var length = table.length;
  var output = [];
  var indexB = table[1];
  var initial = 0, valueE = 0;
  for (var index = 0; index < bytes.length; index++) {
    var sum;
    if (index === 0) { initial = table[indexB]; sum = indexB + initial; table[1] = initial; table[indexB] = indexB; }
    else sum = initial + valueE;
    output.push(bytes[index] ^ table[sum % length]);
    var next = (index + 2) % length;
    valueE = table[next];
    sum = (indexB + valueE) % length;
    initial = table[sum];
    table[sum] = table[next];
    table[next] = initial;
    indexB = sum;
  }
  return output;
}
function DOUYIN_LL_randomPrefix(randInt){
  var out = [];
  for (var group = 0; group < 3; group++) {
    var value = randInt(10000);
    out.push((value & 255 & 170) | 1, (value & 255 & 85) | 2, ((value >> 8) & 170) | 5, ((value >> 8) & 85) | 40);
  }
  return out;
}
function DOUYIN_LL_randomFingerprint(randInt){
  function between(low, high){ return low + randInt(high - low + 1); }
  var innerW = between(1024, 1920), innerH = between(768, 1080);
  var outerW = innerW + between(24, 32), outerH = innerH + between(75, 90);
  var screenY = [0, 30][randInt(2)];
  var sizeW = between(1024, 1920), sizeH = between(768, 1080);
  var availW = between(1280, 1920), availH = between(800, 1080);
  return innerW + '|' + innerH + '|' + outerW + '|' + outerH + '|0|' + screenY + '|0|0|' + sizeW + '|' + sizeH + '|' + availW + '|' + availH + '|' + innerW + '|' + innerH + '|24|24|Win32';
}

// ---- Signer. Port of DouyinSigner (factory: injectable UA / fingerprint /
// clock / random, so the Pure Live test vectors can be replayed). ----
function DOUYIN_LL_createSigner(cfg){
  cfg = cfg || {};
  var userAgent = cfg.userAgent || DOUYIN_LL_UA;
  var randInt = cfg.randInt || DOUYIN_LL_randInt;
  var nowMs = cfg.nowMs || function(){ return Date.now(); };
  var fingerprint = cfg.fingerprint || DOUYIN_LL_randomFingerprint(randInt);
  function msToken(length){
    length = (length === undefined) ? 184 : length;
    var s = '';
    for (var i = 0; i < length; i++) s += DOUYIN_LL_MSTOKEN_ALPHABET[randInt(DOUYIN_LL_MSTOKEN_ALPHABET.length)];
    return s;
  }
  function aBogus(query, body){
    body = body || '';
    var start = nowMs();
    var paramsHash = DOUYIN_LL_sm3(DOUYIN_LL_sm3(DOUYIN_LL_utf8(query + DOUYIN_LL_SALT)));
    var bodyHash = DOUYIN_LL_sm3(DOUYIN_LL_sm3(DOUYIN_LL_utf8(body + DOUYIN_LL_SALT)));
    var uaHash = DOUYIN_LL_sm3(DOUYIN_LL_utf8(DOUYIN_LL_base64(DOUYIN_LL_rc4(DOUYIN_LL_UA_KEY, DOUYIN_LL_utf8(userAgent)), DOUYIN_LL_ALPHABET1)));
    var end = nowMs();
    var fields = {};
    fields[8] = 3; fields[18] = 44; fields[66] = 0; fields[69] = 0; fields[70] = 0; fields[71] = 0;
    fields[20] = (start >>> 24) & 255; fields[21] = (start >>> 16) & 255; fields[22] = (start >>> 8) & 255; fields[23] = start & 255;
    fields[24] = 0; fields[25] = 0;
    fields[26] = (DOUYIN_LL_OPTIONS[0] >>> 24) & 255; fields[27] = (DOUYIN_LL_OPTIONS[0] >>> 16) & 255;
    fields[28] = (DOUYIN_LL_OPTIONS[0] >>> 8) & 255; fields[29] = DOUYIN_LL_OPTIONS[0] & 255;
    fields[30] = Math.floor(DOUYIN_LL_OPTIONS[1] / 256) & 255; fields[31] = DOUYIN_LL_OPTIONS[1] % 256;
    fields[32] = (DOUYIN_LL_OPTIONS[1] >>> 24) & 255; fields[33] = (DOUYIN_LL_OPTIONS[1] >>> 16) & 255;
    fields[34] = (DOUYIN_LL_OPTIONS[2] >>> 24) & 255; fields[35] = (DOUYIN_LL_OPTIONS[2] >>> 16) & 255;
    fields[36] = (DOUYIN_LL_OPTIONS[2] >>> 8) & 255; fields[37] = DOUYIN_LL_OPTIONS[2] & 255;
    fields[38] = paramsHash[21]; fields[39] = paramsHash[22];
    fields[40] = bodyHash[21]; fields[41] = bodyHash[22];
    fields[42] = uaHash[23]; fields[43] = uaHash[24];
    fields[44] = (end >>> 24) & 255; fields[45] = (end >>> 16) & 255; fields[46] = (end >>> 8) & 255; fields[47] = end & 255;
    fields[48] = 3; fields[49] = 0; fields[50] = 0;
    fields[51] = (DOUYIN_LL_PAGE_ID >>> 24) & 255; fields[52] = (DOUYIN_LL_PAGE_ID >>> 16) & 255;
    fields[53] = (DOUYIN_LL_PAGE_ID >>> 8) & 255; fields[54] = DOUYIN_LL_PAGE_ID & 255; fields[55] = DOUYIN_LL_PAGE_ID;
    fields[56] = DOUYIN_LL_AID; fields[57] = DOUYIN_LL_AID & 255;
    fields[58] = (DOUYIN_LL_AID >>> 8) & 255; fields[59] = (DOUYIN_LL_AID >>> 16) & 255; fields[60] = (DOUYIN_LL_AID >>> 24) & 255;
    fields[64] = fingerprint.length; fields[65] = fingerprint.length;
    var values = [];
    for (var i = 0; i < DOUYIN_LL_ORDER.length; i++) values.push(fields[DOUYIN_LL_ORDER[i]] || 0);
    for (var c = 0; c < fingerprint.length; c++) values.push(fingerprint.charCodeAt(c) & 255);
    var check = 0;
    for (var k = 0; k < DOUYIN_LL_CHECK_ORDER.length; k++) check ^= (fields[DOUYIN_LL_CHECK_ORDER[k]] || 0);
    values.push(check);
    return DOUYIN_LL_encode(DOUYIN_LL_randomPrefix(randInt).concat(DOUYIN_LL_transform(values)));
  }
  function signedUrl(base, params){
    var u;
    try { u = new URL(base); } catch (e) { throw new Error('DOUYIN_LL bad base url: ' + base); }
    var all = {}, order = [];
    function put(k, v){ k = String(k); if (!(k in all)) order.push(k); all[k] = String(v); }
    if (u.search) {
      u.search.slice(1).split('&').forEach(function(pair){
        if (!pair) return;
        var eq = pair.indexOf('='), k = eq < 0 ? pair : pair.slice(0, eq), v = eq < 0 ? '' : pair.slice(eq + 1);
        try { k = decodeURIComponent(k.replace(/\+/g, ' ')); } catch (e) {}
        try { v = decodeURIComponent(v.replace(/\+/g, ' ')); } catch (e) {}
        put(k, v);
      });
    }
    Object.keys(params || {}).forEach(function(k){ put(k, params[k]); });
    put('aid', '6383'); put('compress', 'gzip'); put('device_platform', 'web');
    put('browser_language', 'zh-CN'); put('browser_platform', 'Win32');
    put('browser_name', 'Edge'); put('browser_version', '125.0.0.0');
    if (!('msToken' in all)) put('msToken', msToken());
    var query = order.map(function(k){ return DOUYIN_LL_enc(k) + '=' + DOUYIN_LL_enc(all[k]); }).join('&');
    return u.protocol + '//' + u.host + u.pathname + '?' + query + '&a_bogus=' + aBogus(query);
  }
  function xBogus(msStub, counter){
    counter = (counter === undefined) ? 1 : counter;
    if (!/^[0-9a-fA-F]{32}$/.test(msStub)) throw new Error('xBogus: expected 32 hex digits');
    var random1 = randInt(256), random2 = randInt(255);
    var raw = [];
    for (var i = 0; i < 16; i++) raw.push(parseInt(msStub.substr(i * 2, 2), 16));
    var digest = DOUYIN_LL_md5(raw);
    var payload = [counter & 0x3f, 0, 1, 0x0e, 0x45, 0x3f, digest[14], digest[15], random2, 0];
    for (var i = 0; i < 9; i++) payload[9] ^= payload[i];
    var encrypted = DOUYIN_LL_rc4([random2], payload);
    var bytes = [0x40 | (random1 & 0x1f), random2].concat(encrypted);
    return DOUYIN_LL_base64(bytes, DOUYIN_LL_XBOGUS_ALPHABET);
  }
  function danmakuSignature(roomId, userUniqueId){
    var stub = ['live_id=1', 'aid=6383', 'version_code=180800', 'webcast_sdk_version=1.0.15', 'room_id=' + roomId, 'sub_room_id=', 'sub_channel_id=', 'did_rule=3', 'user_unique_id=' + userUniqueId, 'device_platform=web', 'device_type=', 'ac=', 'identity=audience'].join(',');
    return xBogus(DOUYIN_LL_md5Hex(DOUYIN_LL_utf8(stub)));
  }
  function visitorId(){
    var s = '7' + String(3 + randInt(7));
    for (var i = 0; i < 17; i++) s += String(randInt(10));
    return s;
  }
  return { userAgent: userAgent, fingerprint: fingerprint, msToken: msToken, aBogus: aBogus, signedUrl: signedUrl, xBogus: xBogus, danmakuSignature: danmakuSignature, visitorId: visitorId };
}
// One signer per page load (fingerprint fixed for the session, like
// Pure Live's per-process signer; the cipher table is re-copied per call).
const DOUYIN_LL_signer = DOUYIN_LL_createSigner({});

// ---- small JSON helpers (port of DouyinApi._map/_text/_first*). ----
function DOUYIN_LL_asMap(v){
  if (v && typeof v === 'object' && !Array.isArray(v)) return v;
  if (typeof v === 'string' && v.trim().charAt(0) === '{') { try { var d = JSON.parse(v); return (d && typeof d === 'object' && !Array.isArray(d)) ? d : null; } catch (e) { return null; } }
  return null;
}
function DOUYIN_LL_text(v){
  if (v === null || v === undefined || typeof v === 'object') return null;
  var t = String(v).trim();
  return (!t || t === 'null') ? null : t;
}
function DOUYIN_LL_firstText(values){
  for (var i = 0; i < values.length; i++) { var t = DOUYIN_LL_text(values[i]); if (t !== null) return t; }
  return null;
}
function DOUYIN_LL_firstId(values){
  for (var i = 0; i < values.length; i++) {
    var t = DOUYIN_LL_text(values[i]);
    if (t !== null && ['0', 'undefined', 'nan', 'none'].indexOf(t.toLowerCase()) < 0) return t;
  }
  return null;
}
function DOUYIN_LL_jsonInt(v){
  if (typeof v === 'number' && isFinite(v)) return Math.trunc(v);
  if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) { var n = parseInt(v.trim(), 10); return isFinite(n) ? n : null; }
  return null;
}
function DOUYIN_LL_firstImage(cands){
  for (var i = 0; i < cands.length; i++) {
    var v = cands[i], m = DOUYIN_LL_asMap(v);
    if (m && Array.isArray(m.url_list)) { var u = DOUYIN_LL_firstText(m.url_list); if (u) return u; }
    var d = DOUYIN_LL_text(v);
    if (d && (d.indexOf('http://') === 0 || d.indexOf('https://') === 0)) return d;
  }
  return '';
}
function DOUYIN_LL_lookup(map, key){
  if (!map) return undefined;
  if (map[key] !== undefined) return map[key];
  var lk = String(key).toLowerCase(), ks = Object.keys(map);
  for (var i = 0; i < ks.length; i++) if (ks[i].toLowerCase() === lk) return map[ks[i]];
  return undefined;
}
function DOUYIN_LL_streamType(u){
  return /\.m3u8(\?|$)/i.test(String(u || '')) ? 'hls' : 'flv';
}
// Online count: enter/reflow answers carry user_count_str ("3000+") but
// often no numeric user_count (feed rooms do have it).
function DOUYIN_LL_online(room){
  var n = DOUYIN_LL_jsonInt(room.user_count);
  if (n === null) n = DOUYIN_LL_jsonInt(room.online_user_count);
  if (n !== null) return n;
  var s = DOUYIN_LL_text(room.user_count_str);
  if (s) { var m = s.match(/\d+/); if (m) return parseInt(m[0], 10); }
  return 0;
}

// ---- Qualities from stream_url. Port of DouyinApi._variants/qualities/
// resolution: stream_data (data.{sdk_key}.main) + flv_pull_url /
// hls_pull_url_map joined by sdk_key case-insensitively, audio-only keys
// dropped, same-URL keys merged, best first. Unlike the old
// directDyQualitiesFromStreamUrl in app.js this keeps FLV lines too
// (FLV first, then HLS, as the platform lists them) — each quality's
// urls[] is its lines, so the player can switch line without re-fetching.
function DOUYIN_LL_qualitiesFromStreamUrl(su){
  if (!su || typeof su !== 'object') return [];
  var lcd = DOUYIN_LL_asMap(su.live_core_sdk_data) || {};
  var pull = DOUYIN_LL_asMap(lcd.pull_data) || {};
  var options = DOUYIN_LL_asMap(pull.options) || {};
  var streamData = DOUYIN_LL_asMap(DOUYIN_LL_asMap(pull.stream_data) ? DOUYIN_LL_asMap(pull.stream_data).data : null) || {};
  var flvMap = DOUYIN_LL_asMap(su.flv_pull_url) || {};
  var hlsMap = DOUYIN_LL_asMap(su.hls_pull_url_map) || {};
  var names = DOUYIN_LL_asMap(su.resolution_name) || {};
  var defaultQuality = DOUYIN_LL_asMap(options.default_quality) || null;
  var defaultKey = null;
  if (defaultQuality && defaultQuality.sdk_key) defaultKey = String(defaultQuality.sdk_key).toLowerCase();
  else if (su.default_resolution) defaultKey = String(su.default_resolution).toLowerCase();
  var desc = {};
  var qlist = Array.isArray(options.qualities) ? options.qualities : [];
  qlist.forEach(function(o){
    var m = DOUYIN_LL_asMap(o), k = m && DOUYIN_LL_text(m.sdk_key);
    if (m && k) desc[k.toLowerCase()] = m;
  });
  var keySet = {};
  Object.keys(desc).forEach(function(k){ keySet[k] = true; });
  Object.keys(streamData).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  Object.keys(flvMap).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  Object.keys(hlsMap).forEach(function(k){ if (String(k).trim()) keySet[String(k).toLowerCase()] = true; });
  function audioOnly(key, lines){
    var token = key.toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (token === 'ao' || token === 'audio' || token === 'audioonly') return true;
    return lines.every(function(l){
      var q = '';
      try { q = (new URL(l.url).searchParams.get('only_audio') || '').toLowerCase(); } catch (e) {}
      return q === '1' || q === 'true';
    });
  }
  function codecOf(v){
    var t = (DOUYIN_LL_text(v) || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (t === 'h264' || t === '264' || t === 'avc' || t === 'avc1') return 'avc';
    if (t === 'h265' || t === '265' || t === 'hevc' || t === 'hev1' || t === 'hvc1' || t === 'bytevc1') return 'hevc';
    return null;
  }
  var ranked = [];
  Object.keys(keySet).forEach(function(key){
    var entry = DOUYIN_LL_asMap(DOUYIN_LL_lookup(streamData, key));
    var main = entry ? DOUYIN_LL_asMap(entry.main) : null;
    var lines = [];
    function add(value, format){
      var u = DOUYIN_LL_text(value);
      if (!u) return;
      var uri = null;
      try { uri = new URL(u); } catch (e) { return; }
      if ((uri.protocol !== 'http:' && uri.protocol !== 'https:') || !uri.host) return;
      var s = uri.toString();
      for (var i = 0; i < lines.length; i++) if (lines[i].url === s) return;
      lines.push({ url: s, format: format });
    }
    if (main) { add(main.flv, 'flv'); add(main.hls, 'hls'); }
    add(DOUYIN_LL_lookup(flvMap, key), 'flv');
    add(DOUYIN_LL_lookup(hlsMap, key), 'hls');
    if (!lines.length || audioOnly(key, lines)) return;
    var sdk = main ? (DOUYIN_LL_asMap(main.sdk_params) || {}) : {};
    var d = desc[key] || {};
    var bitrate = DOUYIN_LL_jsonInt(d.v_bit_rate);
    if (bitrate === null) bitrate = DOUYIN_LL_jsonInt(sdk.vbitrate);
    var level = DOUYIN_LL_jsonInt(d.level) || 0;
    var upKey = key.toUpperCase();
    var tier = DOUYIN_LL_Q_TIER[upKey] || 0;
    var sort = tier > 0 ? tier : (level > 0 ? level * 1000000 : (bitrate || 0));
    var name = DOUYIN_LL_text(d.name) || DOUYIN_LL_text(DOUYIN_LL_lookup(names, key)) || DOUYIN_LL_Q_NAME[upKey] || upKey;
    ranked.push({
      id: upKey, name: name, bitrate: bitrate || 0, sort: sort,
      urls: lines.map(function(l){ return l.url; }),
      codec: codecOf(sdk.VCodec) || codecOf(d.v_codec) || undefined
    });
  });
  ranked.sort(function(a, b){ return (b.sort - a.sort) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0); });
  var kept = [], bySet = {};
  ranked.forEach(function(v){
    var set = v.urls.slice().sort().join('\u0000');
    if (bySet[set] !== undefined) return; // same URLs as a better-ranked key: alias, drop
    bySet[set] = kept.length;
    var q = { id: v.id, name: v.name, bitrate: v.bitrate, urls: v.urls };
    if (v.codec) q.codec = v.codec;
    kept.push(q);
  });
  return kept;
}

// ---- Primary play: signed /webcast/room/web/enter/. Port of
// DouyinSite._enter + DouyinApi.enter. Returns the same shape as the old
// directDyRoomPlay: {url, type, quality, qualities, room} or null.
async function DOUYIN_LL_enter(webRid){
  await directDyPrime();
  var url = DOUYIN_LL_signer.signedUrl('https://live.douyin.com/webcast/room/web/enter/', {
    app_name: 'douyin_web', enter_from: 'web_live', live_id: '1',
    web_rid: String(webRid), is_need_double_stream: 'false'
  });
  var j = await nativeJson(url, { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
  if (!j || j.status_code !== 0 || !j.data || !Array.isArray(j.data.data) || !j.data.data.length) return null;
  var room = j.data.data[0] || {};
  var stNum = DOUYIN_LL_jsonInt(room.status);
  var live = (stNum !== null) ? (stNum === 2) : (DOUYIN_LL_jsonInt(j.data.room_status) === 0);
  if (!live) return null;
  var qs = DOUYIN_LL_qualitiesFromStreamUrl(room.stream_url || null);
  if (!qs.length) return null;
  var wr = String(webRid);
  try {
    __dyStreamUrls.set(wr, room.stream_url || {});
    __dyHlsMaps.set(wr, (room.stream_url || {}).hls_pull_url_map || {});
    var r19 = directDyPickRoomId(room);
    if (r19) __dyRoomIdMap.set(wr, r19);
  } catch (e) {}
  var owner = room.owner || {};
  return {
    url: qs[0].urls[0], type: DOUYIN_LL_streamType(qs[0].urls[0]), quality: qs[0].id, qualities: qs,
    room: { roomId: wr, title: room.title || '', uname: owner.nickname || '', online: DOUYIN_LL_online(room), status: room.status }
  };
}

// ---- Real search: parse helpers. Port of DouyinApi.searchRooms /
// _searchRoom / _chunks. The general-search endpoint frames its body as
// <hex byte length>\r\n<document>\r\n chunks ending with 0\r\n\r\n.
function DOUYIN_LL_searchChunks(body){
  if (!/^[0-9a-fA-F]+\r?\n/.test(body)) return [body];
  var bytes = DOUYIN_LL_utf8(body), docs = [], pos = 0;
  function latin1(arr){ var s = ''; for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]); return s; }
  while (pos < bytes.length) {
    var nl = bytes.indexOf(10, pos);
    if (nl < 0) break;
    var size = parseInt(latin1(bytes.slice(pos, nl)).trim().split(';')[0], 16);
    if (isNaN(size)) throw new Error('search: bad chunk header');
    if (size === 0) break;
    var start = nl + 1;
    if (start + size > bytes.length) throw new Error('search: truncated chunk');
    docs.push(DOUYIN_LL_utf8Decode(bytes.slice(start, start + size)));
    pos = start + size;
    if (bytes[pos] === 13) pos++;
    if (bytes[pos] === 10) pos++;
  }
  if (!docs.length) throw new Error('search: no chunk');
  return docs;
}
function DOUYIN_LL_parseSearchRoom(item){
  item = DOUYIN_LL_asMap(item) || {};
  function at(node, key){ var m = DOUYIN_LL_asMap(node); return m ? m[key] : undefined; }
  var lives = at(item, 'lives'), live = at(item, 'live'), liveInfo = at(item, 'live_info');
  var awemeInfo = at(item, 'aweme_info'), data = at(item, 'data');
  var awemeLive = awemeInfo ? at(awemeInfo, 'live_info') : undefined;
  var cands = [
    at(lives, 'rawdata'), at(lives, 'raw_data'), at(live, 'rawdata'), at(liveInfo, 'rawdata'),
    at(awemeLive, 'rawdata'), at(data, 'rawdata'), item.rawdata, item.lives, item.live,
    item.live_info, awemeLive, item.aweme_info, item.data, item
  ];
  var raw = null;
  for (var i = 0; i < cands.length; i++) { var m = DOUYIN_LL_asMap(cands[i]); if (m) { raw = m; break; } }
  if (!raw) return null;
  var room = DOUYIN_LL_asMap(raw.room) || {};
  var owner = DOUYIN_LL_asMap(raw.owner) || {};
  var roomOwner = DOUYIN_LL_asMap(room.owner) || {};
  var roomId = DOUYIN_LL_firstId([raw.id_str, raw.room_id_str, room.id_str, room.id, raw.room_id, raw.roomId]);
  if (!roomId) return null;
  var id = DOUYIN_LL_firstId([owner.web_rid, raw.web_rid, roomOwner.web_rid]) || roomId;
  var nickname = DOUYIN_LL_firstText([owner.nickname, raw.nickname, roomOwner.nickname, item.nickname]) || '';
  var roadMap = Array.isArray(room.partition_road_map) ? room.partition_road_map : [];
  var roadTitle = null;
  if (roadMap.length) { var rm0 = DOUYIN_LL_asMap(roadMap[0]); if (rm0) roadTitle = DOUYIN_LL_text(rm0.title); }
  var part = DOUYIN_LL_asMap(raw.partition);
  var online = DOUYIN_LL_jsonInt(raw.user_count);
  if (online === null) online = DOUYIN_LL_jsonInt(room.user_count);
  return {
    platform: 'douyin', roomId: String(id),
    title: DOUYIN_LL_firstText([raw.title, room.title, item.title, item.desc, nickname]) || '',
    uname: nickname, online: online || 0,
    cover: DOUYIN_LL_firstImage([owner.avatar_large, raw.cover, room.cover, raw.cover_url]),
    face: DOUYIN_LL_firstImage([owner.avatar_thumb, owner.avatar_large]),
    game: DOUYIN_LL_firstText([raw.video_feed_tag, roadTitle, part ? part.title : undefined, item.search_keyword]) || '',
    live: DOUYIN_LL_jsonInt(raw.status) === 2
  };
}
function DOUYIN_LL_parseSearchRooms(body){
  var docs, items = [];
  try { docs = DOUYIN_LL_searchChunks(String(body || '')); } catch (e) { return []; }
  docs.forEach(function(doc){
    var parsed = null;
    try { parsed = JSON.parse(doc); } catch (e) { return; }
    if (!parsed || typeof parsed !== 'object') return;
    if (parsed.status_code !== undefined && parsed.status_code !== 0) return; // 2483 = login required, etc.
    if (Array.isArray(parsed.data)) items = items.concat(parsed.data);
  });
  var seen = {}, out = [];
  items.forEach(function(item){
    var r = DOUYIN_LL_parseSearchRoom(item);
    if (r && !seen[r.roomId]) { seen[r.roomId] = 1; out.push(r); }
  });
  return out.filter(function(r){ return r.live; });
}
// Partition-name search (anonymous, like Pure Live's _partitionSearch).
async function DOUYIN_LL_partitionSearch(keyword){
  var headers = {
    'User-Agent': DIRECT_LIVE_UA, 'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': 'https://www.douyin.com/search/' + encodeURIComponent(keyword) + '?source=switch_tab&type=live',
    'Origin': 'https://www.douyin.com', 'Sec-Fetch-Dest': 'empty', 'Sec-Fetch-Mode': 'cors', 'Sec-Fetch-Site': 'same-origin'
  };
  var j = await nativeJson('https://live.douyin.com/webcast/web/partition/search/?keyword=' + encodeURIComponent(keyword) + '&aid=6383', { headers: headers }, 15000);
  var list = (((j && j.data) || {}).SearchResult) || [];
  var out = [];
  list.forEach(function(it){
    var p = (it && it.partition) || {}, id = String(p.id_str || ''), t = p.type;
    if (id && t !== undefined && t !== null && t !== '') out.push({ id: id + ',' + String(t), name: p.title || '' });
  });
  return out;
}

// ---- Overrides (same names as app.js; this file loads after it). ----

// Room play by 19-digit broadcast room_id: reflow/info first (as before),
// but an ended broadcast (status 4) or a reflow answer with no stream now
// re-enters by the owner's web_rid (Pure Live _fetch), and qualities now
// carry FLV + HLS lines per quality.
async function directDyRoomPlayById(roomId){
  await directDyPrime();
  var rid = String(roomId || '');
  try {
    var j = await nativeJson('https://webcast.amemv.com/webcast/room/reflow/info/?type_id=0&live_id=1&room_id=' + encodeURIComponent(rid) + '&sec_user_id=&version_code=99.99.99&app_id=6383', { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
    if (j && j.status_code === 0 && j.data && j.data.room) {
      var room = j.data.room;
      var qs = DOUYIN_LL_qualitiesFromStreamUrl(room.stream_url || null);
      var webRid = (room.owner && room.owner.web_rid) ? String(room.owner.web_rid) : '';
      if ((!qs.length || DOUYIN_LL_jsonInt(room.status) === 4) && webRid) {
        try { var e = await DOUYIN_LL_enter(webRid); if (e) return e; } catch (err) {}
      }
      if (!qs.length) return null;
      if (webRid) { try { __dyStreamUrls.set(webRid, room.stream_url || {}); } catch (err) {} }
      var owner = room.owner || {};
      return {
        url: qs[0].urls[0], type: DOUYIN_LL_streamType(qs[0].urls[0]), quality: qs[0].id, qualities: qs,
        room: { roomId: String(room.id_str || rid), title: room.title || '', uname: owner.nickname || '', online: DOUYIN_LL_online(room), status: room.status }
      };
    }
  } catch (e) {}
  return null;
}

// Room play by web_rid: cached stream -> 19-digit room_id -> cached HLS
// map -> SIGNED room/web/enter/ (new primary path) -> room-page scrape
// (last resort, as before). reflow/info is only used via
// directDyRoomPlayById for 19-digit ids, not as the primary path.
async function directDyRoomPlay(webRid){
  var wr = String(webRid || '');
  if (/^7\d{18}$/.test(wr)) { try { var out0 = await directDyRoomPlayById(wr); if (out0) return out0; } catch (e) {} }
  var su0 = __dyStreamUrls.get(wr);
  if (su0) {
    var qs0 = DOUYIN_LL_qualitiesFromStreamUrl(su0);
    if (qs0.length && directDyUrlFresh(qs0[0].urls[0])) return { url: qs0[0].urls[0], type: DOUYIN_LL_streamType(qs0[0].urls[0]), quality: qs0[0].id, qualities: qs0 };
    __dyStreamUrls.delete(wr);
  }
  var rid19 = __dyRoomIdMap.get(wr);
  if (rid19) { try { var out1 = await directDyRoomPlayById(rid19); if (out1) return out1; } catch (e) {} }
  var m0 = directDyHlsMapGet(wr);
  if (m0) {
    var qsm = directDyQualitiesFromMap(m0);
    if (qsm.length && directDyUrlFresh(qsm[0].urls[0])) return { url: qsm[0].urls[0], type: 'hls', quality: qsm[0].id, qualities: qsm };
    __dyHlsMaps.delete(wr);
  }
  try { var out2 = await DOUYIN_LL_enter(wr); if (out2) return out2; } catch (e) {}
  await directDyPrime();
  var html = await nativeText('https://live.douyin.com/' + encodeURIComponent(wr), { headers: { 'User-Agent': DIRECT_LIVE_UA, 'Referer': 'https://live.douyin.com' } }, 15000);
  var u = html.replace(/\\"/g, '"').replace(/\\u0026/g, '&');
  var idm = u.match(/"id_str":"(7[0-9]{18})"/);
  if (idm) { __dyRoomIdMap.set(wr, idm[1]); if (__dyRoomIdMap.size > 500) __dyRoomIdMap.delete(__dyRoomIdMap.keys().next().value); }
  var i = u.indexOf('hls_pull_url_map');
  if (i < 0) return null;
  var seg = u.slice(i, i + 20000);
  var map = {};
  var re = /"(ORIGION|ORIGIN|FULL_HD1|UHD|HD1|HD|SD2|SD|SD1|LD|MD)"\s*:\s*"(https?:\/\/[^"]+\.m3u8[^"]*)"/g;
  var mm;
  while ((mm = re.exec(seg)) !== null) { if (!map[mm[1]]) map[mm[1]] = mm[2]; }
  var qs = directDyQualitiesFromMap(map);
  if (!qs.length) return null;
  return { url: qs[0].urls[0], type: 'hls', quality: qs[0].id, qualities: qs };
}

// ---- Real search (new). Port of DouyinSite.searchRooms: live search,
// then general search (both need a signed-in cookie — anonymous requests
// answer 2483, so expect these to fail without a login), then the rooms
// of the first 3 partitions whose name matches the keyword, then — only
// so search does not regress vs the old feed filter — the feed substring
// match (searchVia 'feed'). Returns the
// same room shape as directLiveSearch: {platform, roomId, title, uname,
// online, cover, face, game, live} plus searchVia ('live' | 'general' |
// 'partition'). Never throws: [] on total failure.
async function directDySearchLive(keyword, page, pageSize){
  var q = String(keyword || '').trim();
  if (!q) return [];
  var count = Math.max(1, Math.min(50, parseInt(pageSize || '20', 10) || 20));
  var pg = Math.max(1, parseInt(page || '1', 10) || 1);
  var offset = count * (pg - 1);
  await directDyPrime();
  var headers = {
    'User-Agent': DIRECT_LIVE_UA, 'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': 'https://www.douyin.com/search/' + encodeURIComponent(q) + '?source=switch_tab&type=live',
    'Origin': 'https://www.douyin.com', 'Sec-Fetch-Dest': 'empty', 'Sec-Fetch-Mode': 'cors', 'Sec-Fetch-Site': 'same-origin'
  };
  var attempts = [
    { path: '/aweme/v1/web/live/search/', via: 'live', extra: { search_source: 'switch_tab', query_correct_type: '1', need_filter_settings: '1', list_type: 'single' } },
    { path: '/aweme/v1/web/general/search/stream/', via: 'general', extra: {} }
  ];
  for (var a = 0; a < attempts.length; a++) {
    var att = attempts[a];
    var params = 'device_platform=webapp&aid=6383&channel=channel_pc_web&search_channel=aweme_live';
    Object.keys(att.extra).forEach(function(k){ params += '&' + DOUYIN_LL_enc(k) + '=' + DOUYIN_LL_enc(att.extra[k]); });
    params += '&keyword=' + encodeURIComponent(q) + '&offset=' + offset + '&count=' + count + '&os_version=10';
    try {
      var r = await nativeFetch('https://www.douyin.com' + att.path + '?' + params, { headers: headers }, 15000);
      if (r.status < 200 || r.status >= 300) continue;
      var rooms = DOUYIN_LL_parseSearchRooms(r.text);
      if (rooms.length) {
        rooms.forEach(function(rm){ rm.searchVia = att.via; });
        return rooms;
      }
    } catch (e) {}
  }
  var out = [], seen = {};
  try {
    var areas = await DOUYIN_LL_partitionSearch(q);
    for (var p = 0; p < Math.min(3, areas.length); p++) {
      var area = areas[p], arr = [];
      try { arr = await directDyPartitionRoomsByCat(area.id, 1); } catch (e) { arr = []; }
      for (var n = 0; n < arr.length; n++) {
        var r = arr[n];
        if (!r || !r.roomId || seen[r.roomId]) continue;
        seen[r.roomId] = 1;
        out.push({ platform: 'douyin', roomId: r.roomId, title: r.title || '', uname: r.uname || '', online: r.online || 0, cover: r.cover || '', face: r.face || '', game: area.name || '', live: true, searchVia: 'partition' });
        if (out.length >= count) return out;
      }
    }
  } catch (e) {}
  if (out.length) return out;
  // Last resort (keeps the old behaviour instead of regressing it): the
  // feed is one random draw, so a streamer-name query only matches when
  // the streamer happens to be in this draw. Marked searchVia 'feed'.
  try {
    var feed = await directDyFeed(), ql = q.toLowerCase();
    feed.forEach(function(fr){
      var hay = ((fr.title || '') + ' ' + (fr.uname || '')).toLowerCase();
      if (hay.indexOf(ql) >= 0 && !seen[fr.roomId]) {
        seen[fr.roomId] = 1;
        out.push({ platform: 'douyin', roomId: fr.roomId, title: fr.title || '', uname: fr.uname || '', online: fr.online || 0, cover: fr.cover || '', face: fr.face || '', game: '', live: true, searchVia: 'feed' });
      }
    });
  } catch (e) {}
  return out;
}

// ---- API hosts used by this file (nativeFetch allowlist) ----
// live.douyin.com — room/web/enter/ (signed a_bogus), webcast/web/
//   partition/detail/room/v2/, webcast/web/partition/search/, room page,
//   homepage prime. (Already allowlisted.)
// webcast.amemv.com — webcast/room/reflow/info/. (Already allowlisted.)
// www.douyin.com — NEW, add to ViewController.allowedHosts:
//   /aweme/v1/web/live/search/ + /aweme/v1/web/general/search/stream/
//   (real search; anonymous requests answer 2483, then the partition
//   fallback runs — search still works, just by category name).
// Media (stream) hosts are dynamic per play URL (pull-hls-*/pull-flv-*
// douyincdn domains and similar) and are fetched by the player, not by
// nativeFetch, so they need no allowlist entry here.

// live-lines-ks.js — Kuaishou room-page play (Pure Live port).
//
// Loaded AFTER app.js; the `function` declarations below (directKsPlay,
// directKsPlayByPage) override the app.js versions of the same name.
// Everything new in this file is prefixed KS_LL_ so it cannot collide
// with app.js names. Do NOT edit app.js to integrate this file — just
// load this script after it.
//
// Ported from Pure Live (packages/live_core/lib/src/sites/kuaishou/):
//   - KuaishouApi.initialState / roomDetail  (kuaishou_api.dart)
//   - KuaishouSite._streams / _playItem / _ensureSession / _reportDevice
//     (kuaishou_site.dart)
//   - KuaishouApi.qualities / _tiers / _addTiers (H.264-first ordering)
//   - KuaishouApi.devicePayload / setCookies (misc2 device report)
//
// Behaviour change vs the old directKsPlay: the room page
// https://live.kuaishou.com/u/{id} is now the FIRST attempt (it resolves
// any room directly). The old list-walking search (searchIn over
// directKsRooms) is kept as the fallback when the room page cannot be
// read (rate-limited / verification / offline).
//
// Return shape (unchanged for callers, extended per quality):
//   { url, type: 'flv'|'hls', quality, qualities }
//   qualities: [{ id, name, bitrate, urls: [...], url: urls[0], hevcOnly }]
// `url` on each quality is kept for the old single-url readers;
// liveCurUrls()/liveNativeQualities() already prefer `urls`.

// ---- KS_LL_ constants (new names only; app.js names untouched) ----
const KS_LL_MEDIA_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const KS_LL_PAGE_ACCEPT = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3';
const KS_LL_ORIGIN = 'https://live.kuaishou.com';
const KS_LL_DEVICE_REPORT_URL = 'https://log-sdk.ksapisrv.com/rest/wd/common/log/collect/misc2?v=3.9.49&kpn=KS_GAME_LIVE_PC';
const KS_LL_SESSION_LIFETIME_MS = 30 * 60 * 1000; // Pure Live _sessionLifetime
const KS_LL_HEVC_SUFFIX = ' · H.265';
// Pure Live's fixed misc2 session id (web logger constant, not a secret).
const KS_LL_DEVICE_SESSION_ID = '1eb20f88-51ac-4ecf-8dc3-ace5aefcae4f';

// Mutable session state (var: safe if this file is ever loaded twice).
var KS_LL_sessionSince = 0;
var KS_LL_reportedDid = '';
var KS_LL_reportPromise = null;

// ---- KS_LL_ parsing helpers (port of KuaishouApi internals) ----
function KS_LL_truthy(v){ return v === true || v === 1 || (typeof v === 'string' && v.trim().toLowerCase() === 'true'); }
function KS_LL_text(v){ return v == null ? '' : String(v); }
function KS_LL_isObject(v){ return v !== null && typeof v === 'object' && !Array.isArray(v); }
function KS_LL_list(v){ return Array.isArray(v) ? v : []; }
function KS_LL_fields(v){ return KS_LL_isObject(v) ? v : {}; }

// Absolute http(s) URL only (Pure Live _mediaUri).
function KS_LL_mediaUrl(u){
  if (typeof u !== 'string') return '';
  const s = u.trim();
  if (s.indexOf('http://') !== 0 && s.indexOf('https://') !== 0) return '';
  try { const p = new URL(s); return p.host ? s : ''; } catch (e) { return ''; }
}

// Codec from a card URL's file name: `{id}_GameAvcHdL0.flv` -> avc,
// `{id}_...Hevc....flv` -> hevc (Pure Live _codecOf).
function KS_LL_codecOfUrl(url){
  try {
    const parts = url.split('/');
    const file = parts[parts.length - 1] || '';
    const tail = file.split('_').pop() || '';
    const m = tail.match(/^[A-Za-z]*?(Avc|Hevc|H264|H265)/);
    if (!m) return null;
    return (m[1] === 'Avc' || m[1] === 'H264') ? 'avc' : 'hevc';
  } catch (e) { return null; }
}

function KS_LL_representations(descriptor){
  const map = KS_LL_isObject(descriptor) ? descriptor : null;
  if (!map) return [];
  const set = KS_LL_isObject(map.adaptationSet) ? map.adaptationSet : null;
  const reps = set ? set.representation : map.representation;
  return KS_LL_list(reps);
}

// One tier per (name, sort); URLs merged in order without repeats.
// hevcOnly tiers are keyed by name + suffix (Pure Live _addTiers).
function KS_LL_addTiers(tiers, representations, codec, hevcOnly){
  for (const value of representations) {
    const item = KS_LL_isObject(value) ? value : null;
    if (!item) continue;
    const url = KS_LL_mediaUrl(item.url);
    if (!url) continue;
    const sort = Number(item.level != null ? item.level : (item.bitrate != null ? item.bitrate : 0)) || 0;
    const bitrate = Number(item.bitrate) || 0;
    const name = (item.name != null && String(item.name) !== '') ? String(item.name)
      : (item.shortName != null && String(item.shortName) !== '') ? String(item.shortName)
      : (item.qualityType != null && String(item.qualityType) !== '') ? String(item.qualityType)
      : ('清晰度 ' + sort);
    const dispName = hevcOnly ? name + KS_LL_HEVC_SUFFIX : name;
    const key = dispName + '#' + sort;
    let tier = tiers[key];
    if (!tier) tier = tiers[key] = { key: key, name: dispName, sort: sort, bitrate: 0, lines: [], hevcOnly: !!hevcOnly, order: Object.keys(tiers).length };
    if (bitrate > tier.bitrate) tier.bitrate = bitrate;
    if (tier.lines.every(function(l){ return l.url !== url; })) {
      tier.lines.push({ url: url, codec: codec || KS_LL_codecOfUrl(url) });
    }
  }
}

// Pure Live _tiers: per descriptor take the first of h264/avc/hevc/h265
// that has representations, else the descriptor itself (card shape:
// adaptationSet directly on the descriptor). H.265 qualities the H.264
// set lacks (4K, 蓝光 质臻) are appended as hevcOnly tiers.
function KS_LL_tiers(playUrls, preferH264){
  const merged = {};
  const hevc = [];
  const raws = Array.isArray(playUrls) ? playUrls : [playUrls];
  for (const raw of raws) {
    const descriptor = KS_LL_isObject(raw) ? raw : null;
    if (!descriptor) continue;
    let chosen = descriptor;
    let keyCodec = null;
    const pairs = [['h264', 'avc'], ['avc', 'avc'], ['hevc', 'hevc'], ['h265', 'hevc']];
    for (const pair of pairs) {
      if (KS_LL_representations(descriptor[pair[0]]).length) { chosen = descriptor[pair[0]]; keyCodec = pair[1]; break; }
    }
    KS_LL_addTiers(merged, KS_LL_representations(chosen), keyCodec, false);
    if (keyCodec === 'avc') {
      const h = KS_LL_representations(descriptor.hevc).length ? descriptor.hevc : descriptor.h265;
      hevc.push.apply(hevc, KS_LL_representations(h));
    }
  }
  const extra = {};
  KS_LL_addTiers(extra, hevc, 'hevc', true);
  for (const k of Object.keys(extra)) {
    const t = extra[k];
    const plainKey = t.name.replace(KS_LL_HEVC_SUFFIX, '') + '#' + t.sort;
    if (merged[plainKey]) delete extra[k];
  }
  const ordered = Object.keys(merged).map(function(k){ return merged[k]; })
    .concat(Object.keys(extra).map(function(k){ return extra[k]; }));
  const prefer = preferH264 !== false; // "优先 H.264" on by default
  ordered.sort(function(a, b){
    if (prefer && a.hevcOnly !== b.hevcOnly) return a.hevcOnly ? 1 : -1;
    if (b.sort !== a.sort) return b.sort - a.sort;
    return a.order - b.order;
  });
  return ordered;
}

// Pure Live KuaishouApi.qualities, in the {qualities:[...]} shape the
// app already consumes (each quality carries all its CDN lines in urls).
// Default quality = qualities[0]: best H.264 first, HEVC-only after.
function KS_LL_qualitiesFromPlayUrls(playUrls, preferH264){
  return KS_LL_tiers(playUrls, preferH264)
    .filter(function(t){ return t.lines.length; })
    .map(function(t){
      const urls = t.lines.map(function(l){ return l.url; });
      return { id: t.key, name: t.name, bitrate: t.bitrate || t.sort, urls: urls, url: urls[0], hevcOnly: t.hevcOnly };
    });
}

// ---- KS_LL_ room-page parsing (port of initialState / _objectLiteral) ----
// Extracts window.__INITIAL_STATE__ by JSON structure: a `;` inside a
// string does not end it, and only a bare `undefined` becomes null.
function KS_LL_extractInitialState(html){
  const marker = html.match(/window\.__INITIAL_STATE__\s*=\s*/);
  if (!marker) return null;
  let index = marker.index + marker[0].length;
  while (index < html.length && html.charCodeAt(index) <= 0x20) index++;
  if (index >= html.length || html[index] !== '{') return null;
  let out = '';
  let depth = 0;
  let inString = false;
  for (; index < html.length; index++) {
    const ch = html[index];
    if (inString) {
      out += ch;
      if (ch === '\\' && index + 1 < html.length) out += html[++index];
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; out += ch; continue; }
    if (ch === '{' || ch === '[') depth++;
    else if (ch === '}' || ch === ']') {
      depth--;
      out += ch;
      if (depth === 0) {
        try { const state = JSON.parse(out); return KS_LL_isObject(state) ? state : null; }
        catch (e) { return null; }
      }
      continue;
    } else if (html.indexOf('undefined', index) === index) {
      const before = index > 0 ? html[index - 1] : '';
      const after = html[index + 9] || '';
      const isIdent = function(c){ return /[0-9A-Za-z$_]/.test(c); };
      if (!isIdent(before) && !isIdent(after)) { out += 'null'; index += 8; continue; }
    }
    out += ch;
  }
  return null;
}

// Port of KuaishouApi.roomDetail / _playItem: errorType 22 = NotFound,
// any other errorType = RiskControl; isLiving alone decides live/offline.
// Returns { isLiving, liveStreamId, playUrls, nick, avatar, cover, area,
//   liveStreamId } ; throws Error('ks room not found' | 'ks risk control'
// | 'ks room page changed').
function KS_LL_parseRoomPage(html, requestedId){
  const id = String(requestedId || '').trim();
  const state = KS_LL_extractInitialState(html);
  if (!state) {
    if (/captcha|验证码|安全验证|人机验证|滑块/i.test(html)) throw new Error('ks risk control (verification page)');
    throw new Error('ks room page changed (no __INITIAL_STATE__)');
  }
  const liveRoom = KS_LL_fields(state.liveroom);
  const list = KS_LL_list(liveRoom.playList);
  const room = KS_LL_isObject(list[0]) ? list[0] : null;
  if (!room) throw new Error('ks room page changed (liveroom.playList[0] missing)');
  const err = room.errorType;
  if (err != null) {
    const et = KS_LL_isObject(err) ? err : {};
    const type = Number(et.type != null ? et.type : err) || 0;
    const title = KS_LL_text(et.title);
    if (type === 22) throw new Error('ks room not found (errorType 22 ' + title + ')');
    throw new Error('ks risk control (errorType ' + type + ' ' + title + ')');
  }
  const author = KS_LL_fields(room.author);
  const stream = KS_LL_fields(room.liveStream);
  const game = KS_LL_fields(room.gameInfo);
  const counts = KS_LL_fields(author.counts);
  return {
    isLiving: KS_LL_truthy(room.isLiving),
    liveStreamId: stream.id != null ? String(stream.id) : '',
    playUrls: stream.playUrls != null ? stream.playUrls : null,
    nick: KS_LL_text(author.name),
    avatar: KS_LL_text(author.avatar),
    cover: KS_LL_text(stream.poster),
    area: KS_LL_text(game.name),
    followers: counts.fan != null ? String(counts.fan) : '0',
    introduction: KS_LL_text(author.description),
    roomId: id
  };
}

// ---- KS_LL_ device did + misc2 report (port of devicePayload /
// _deviceReport / _reportDevice / _ensureSession) ----
//
// Pure Live: a bare GET of the room page creates the anonymous session;
// its Set-Cookie (did, clientid, client_key, kpn, kuaishou.live.bfb1s)
// is kept 30 min and the did is reported once to the misc2 endpoint.
//
// LIMIT (Swift bridge): nativeFetch returns only {status, text} —
// Set-Cookie headers are NOT visible to JS. The Swift side already stores
// the cookies per host and replays them on later requests, so the session
// priming below still works; but JS cannot read the did value itself.
// KS_LL_reportDevice therefore fires only when a did is known — from
// window.__KS_LL_DID__ (a future Swift hook that hands the did to JS),
// or from a "did" token embedded in the page text. Until Swift exposes
// it, the report is skipped and playback proceeds on the primed cookies.
function KS_LL_devicePayload(did, timestamp, incrementId){
  return {
    common: {
      identity_package: { device_id: did, global_id: '' },
      app_package: { language: 'zh-CN', platform: 10, container: 'WEB', product_name: 'KS_GAME_LIVE_PC' },
      device_package: {
        os_version: 'NT 6.1',
        model: 'Windows',
        ua: 'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36'
      },
      need_encrypt: 'false',
      network_package: { type: 3 },
      h5_extra_attr: '{"sdk_name":"webLogger","sdk_version":"3.9.49","sdk_bundle":"log.common.js","app_version_name":"",'
        + '"host_product":"","resolution":"1600x900","screen_with":1600,"screen_height":900,'
        + '"device_pixel_ratio":1,"domain":"https://live.kuaishou.com"}',
      global_attr: '{}'
    },
    logs: [{
      client_timestamp: timestamp,
      client_increment_id: incrementId,
      session_id: KS_LL_DEVICE_SESSION_ID,
      time_zone: 'GMT+08:00',
      event_package: {
        task_event: {
          type: 1, status: 0, operation_type: 1, operation_direction: 0,
          session_id: KS_LL_DEVICE_SESSION_ID,
          url_package: {
            page: 'GAME_DETAL_PAGE',
            identity: '5316c78e-f0b6-4be2-a076-c8f9d11ebc0a',
            page_type: 2,
            params: '{"game_id":1001,"game_name":"王者荣耀"}'
          },
          element_package: {}
        }
      }
    }]
  };
}

// Best-effort misc2 report of one did; never throws, deduped per did.
// Needs log-sdk.ksapisrv.com on the Swift nativeFetch allowlist (see
// footer); without it nativeFetch refuses and this silently no-ops.
function KS_LL_reportDevice(did){
  if (!did || did === KS_LL_reportedDid) return Promise.resolve(false);
  KS_LL_reportedDid = did;
  const payload = KS_LL_devicePayload(did, Date.now(), 1000 + Math.floor(Math.random() * 9000));
  KS_LL_reportPromise = nativeFetch(KS_LL_DEVICE_REPORT_URL, {
    method: 'POST',
    headers: {
      'User-Agent': KS_LL_MEDIA_UA,
      'Content-Type': 'application/json',
      'Origin': KS_LL_ORIGIN,
      'Referer': KS_LL_ORIGIN + '/'
    },
    body: JSON.stringify(payload),
    timeout: 10000
  }).then(function(){ return true; }).catch(function(){ return false; });
  return KS_LL_reportPromise;
}

// Bare GET of the room page: primes the Swift per-host cookie store
// (Pure Live _ensureSession) and, when the visit itself is a readable
// living room page, returns its HTML so the caller need not fetch again.
// Returns { html } — html may be '' when the bare visit failed.
async function KS_LL_ensureKsSession(roomId){
  const url = KS_LL_ORIGIN + '/u/' + encodeURIComponent(String(roomId).trim());
  let html = '';
  try {
    html = await nativeText(url, {
      headers: {
        'User-Agent': KS_LL_MEDIA_UA,
        'Accept': KS_LL_PAGE_ACCEPT,
        'Sec-Fetch-Dest': 'document',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-User': '?1',
        'Referer': KS_LL_ORIGIN + '/'
      }
    }, 15000);
  } catch (e) { html = ''; }
  if (html) {
    KS_LL_sessionSince = Date.now();
    // Opportunistic did sources (see LIMIT above).
    let did = '';
    try { if (typeof window !== 'undefined' && window.__KS_LL_DID__) did = String(window.__KS_LL_DID__); } catch (e) {}
    if (!did) {
      const m = html.match(/["']did["']\s*[:=]\s*["']([A-Za-z0-9_-]{6,})["']/);
      if (m) did = m[1];
    }
    if (did) KS_LL_reportDevice(did);
  }
  return { html: html };
}

// Room-page headers (Pure Live _pageHeaders): session cookie is replayed
// by the Swift bridge per host, so JS does not set a Cookie header.
function KS_LL_roomPageHeaders(){
  return {
    'User-Agent': KS_LL_MEDIA_UA,
    'Accept': KS_LL_PAGE_ACCEPT + ';q=0.9',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Fetch-User': '?1',
    'Referer': KS_LL_ORIGIN + '/'
  };
}

// ---- directKsPlayByPage (NEW): room-page direct resolution ----
// First attempt of the new directKsPlay. Returns the same shape as
// directKsPlay: { url, type, quality, qualities, liveStreamId, room }.
// Throws when the room is offline / not found / the page is unreadable.
async function directKsPlayByPage(roomId){
  const id = String(roomId || '').trim();
  if (!id) throw new Error('ks room not found (empty room id)');
  const freshSession = !KS_LL_sessionSince || (Date.now() - KS_LL_sessionSince > KS_LL_SESSION_LIFETIME_MS);
  let html = '';
  if (freshSession) {
    const visit = await KS_LL_ensureKsSession(id);
    html = visit.html;
  }
  if (!html) {
    html = await nativeText(KS_LL_ORIGIN + '/u/' + encodeURIComponent(id), { headers: KS_LL_roomPageHeaders() }, 15000);
  }
  const detail = KS_LL_parseRoomPage(html, id);
  if (!detail.isLiving) throw new Error('ks room offline');
  if (!detail.playUrls) throw new Error('ks room has no playUrls (unplayable)');
  const qualities = KS_LL_qualitiesFromPlayUrls(detail.playUrls, true);
  if (!qualities.length) throw new Error('ks room has no playable representation');
  const cur = qualities[0]; // best H.264 first (HEVC-only tiers sort last)
  const type = /\.m3u8(\?|$)/i.test(cur.url) ? 'hls' : 'flv';
  return {
    url: cur.url, type: type, quality: cur.id, qualities: qualities,
    liveStreamId: detail.liveStreamId,
    room: { roomId: id, uname: detail.nick, cover: detail.cover, face: detail.avatar, game: detail.area, title: detail.introduction }
  };
}

// Normalize a cached/legacy quality to the new shape: old entries from
// directKsNormRoom carry a single `url`; new ones carry `urls`.
function KS_LL_normQuality(q){
  if (!q) return null;
  const urls = (q.urls && q.urls.length) ? q.urls.slice() : (q.url ? [q.url] : []);
  if (!urls.length) return null;
  return { id: String(q.id), name: q.name || '', bitrate: Number(q.bitrate) || 0, urls: urls, url: urls[0], hevcOnly: !!q.hevcOnly };
}

function KS_LL_pickQuality(qualities, q){
  const qs = (qualities || []).map(KS_LL_normQuality).filter(function(x){ return !!x; });
  if (!qs.length) return null;
  if (q != null && String(q) !== '') {
    const want = qs.find(function(x){ return String(x.id) === String(q) || (x.name && String(x.name) === String(q)); });
    if (want) return { cur: want, qs: qs };
  }
  return { cur: qs[0], qs: qs };
}

// ---- directKsPlay (OVERRIDE of app.js): room page first, list-walk fallback ----
async function directKsPlay(roomId, gameId, q){
  const id = String(roomId);
  // 1) Cache from the room lists (old single-url shape or new urls shape).
  const cached = (typeof __ksPlayCache !== 'undefined') ? __ksPlayCache.get(id) : null;
  if (cached && Date.now() - cached.t < 600000) {
    const pick = KS_LL_pickQuality(cached.qualities, q);
    if (pick) {
      const type = /\.m3u8(\?|$)/i.test(pick.cur.url) ? 'hls' : 'flv';
      return { url: pick.cur.url, type: type, quality: pick.cur.id, qualities: pick.qs };
    }
  }
  // 2) Room page first (Pure Live _streams via _detail).
  try {
    const page = await directKsPlayByPage(id);
    const pick = KS_LL_pickQuality(page.qualities, q);
    if (pick) {
      try { directKsPlayCacheSet([{ roomId: id, qualities: pick.qs }]); } catch (e) {}
      const type = /\.m3u8(\?|$)/i.test(pick.cur.url) ? 'hls' : 'flv';
      return { url: pick.cur.url, type: type, quality: pick.cur.id, qualities: pick.qs, liveStreamId: page.liveStreamId, room: page.room };
    }
  } catch (e) {
    // Fall through to the list-walk fallback below; the page error is
    // only surfaced when the fallback also fails.
    var pageErr = e;
  }
  // 3) Fallback: old list-walking search (kept verbatim in behaviour).
  async function searchIn(gid, pages){
    for (let pg = 1; pg <= pages; pg++) {
      const rooms = await directKsRooms(gid || '', pg);
      const hit = rooms.find(function(x){ return x.roomId === id; });
      if (hit && hit.qualities && hit.qualities.length) {
        const pick = KS_LL_pickQuality(hit.qualities, q);
        if (pick) {
          const type = /\.m3u8(\?|$)/i.test(pick.cur.url) ? 'hls' : 'flv';
          return { url: pick.cur.url, type: type, quality: pick.cur.id, qualities: pick.qs };
        }
      }
    }
    return null;
  }
  let out = null;
  if (gameId) out = await searchIn(gameId, 3);
  if (!out) out = await searchIn('', 1);
  if (out) return out;
  throw (typeof pageErr !== 'undefined' && pageErr) ? pageErr : new Error('ks room not found (may have ended)');
}

// ---- New API hosts used by this file (for the Swift nativeFetch allowlist) ----
// live.kuaishou.com            — room page + live_api (ALREADY allowlisted)
// log-sdk.ksapisrv.com         — misc2 device report (NEW — add to
//                                ViewController.swift allowedHosts, else
//                                KS_LL_reportDevice is refused with -1 and
//                                silently no-ops; playback is unaffected)
