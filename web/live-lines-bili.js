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
