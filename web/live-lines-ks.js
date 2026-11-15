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
