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
