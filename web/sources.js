/* HAo Studio 独立版 — 源管理模块 (b)
 * 纯 JS，无外部依赖。供 web/app.js 加载后使用，暴露 window.HaoSources。
 * 存储：localStorage，键名前缀 hao_sa_。重装会丢，见导出/导入备份。
 * 全部源免费；不连任何本站服务器；只解析播放链接，不代理流量。
 * 在 Node 下也可 require（测试用），此时 localStorage/fetch 由调用方注入或用内存兜底。
 */
(function (root, factory) {
  var api = factory(root);
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.HaoSources = api;
})(typeof window !== 'undefined' ? window : globalThis, function (root) {
  'use strict';

  /* ---------- 工具 ---------- */
  var LS_PREFIX = 'hao_sa_';
  var KEY_VIDEO = LS_PREFIX + 'video';
  var KEY_MUSIC = LS_PREFIX + 'music';
  var KEY_LIVE = LS_PREFIX + 'live';
  var KEY_DANMAKU = LS_PREFIX + 'danmaku';

  var _mem = {}; // localStorage 不可用时（Node/隐私模式）的内存兜底
  function lsGet(k) {
    try { if (root.localStorage) return root.localStorage.getItem(k); } catch (e) {}
    return Object.prototype.hasOwnProperty.call(_mem, k) ? _mem[k] : null;
  }
  function lsSet(k, v) {
    try { if (root.localStorage) { root.localStorage.setItem(k, v); return; } } catch (e) {}
    _mem[k] = v;
  }
  function lsDel(k) {
    try { if (root.localStorage) root.localStorage.removeItem(k); } catch (e) {}
    delete _mem[k];
  }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function uid(prefix) { return prefix + '_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }
  function getPath(obj, path) {
    if (!path) return obj;
    var cur = obj;
    var parts = String(path).split('.');
    for (var i = 0; i < parts.length; i++) {
      if (cur == null) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }
  function fillTpl(tpl, vars) {
    return String(tpl).replace(/\{(\w+)\}/g, function (m, k) {
      return vars[k] != null ? encodeURIComponent(String(vars[k])) : m;
    });
  }
  // 模板里 {platform}/{id} 等占位符在 URL path 段也需要 encode；body JSON 用原始值替换
  function fillRaw(tpl, vars) {
    return String(tpl).replace(/\{(\w+)\}/g, function (m, k) {
      return vars[k] != null ? String(vars[k]) : m;
    });
  }

  /* fetch：优先用 app.js 的 nativeJson（Swift 桥，无 CORS 限制），否则裸 fetch。
   * timeout 毫秒。返回 {status, json?, text?}；失败抛错。 */
  function haoFetch(url, opts, timeout) {
    opts = opts || {};
    timeout = timeout || 8000;
    if (typeof root.nativeJson === 'function' && !opts._forceFetch) {
      return Promise.resolve().then(function () {
        return root.nativeJson(url, {
          method: opts.method || 'GET',
          headers: opts.headers || {},
          body: opts.body || ''
        }, timeout);
      }).then(function (j) { return { status: 200, json: j, text: typeof j === 'string' ? j : JSON.stringify(j) }; });
    }
    var ctrl = null, timer = null;
    try {
      if (typeof AbortController !== 'undefined') {
        ctrl = new AbortController();
        timer = setTimeout(function () { ctrl.abort(); }, timeout);
      }
    } catch (e) {}
    var fopts = { method: opts.method || 'GET', headers: opts.headers || {} };
    if (opts.body != null) fopts.body = opts.body;
    if (ctrl) fopts.signal = ctrl.signal;
    return (typeof fetch !== 'undefined' ? fetch(url, fopts) : Promise.reject(new Error('no fetch available')))
      .then(function (r) {
        if (timer) clearTimeout(timer);
        return r.text().then(function (t) {
          var j = null;
          try { j = JSON.parse(t); } catch (e) {}
          return { status: r.status, ok: r.ok, json: j, text: t };
        });
      })
      .catch(function (e) { if (timer) clearTimeout(timer); throw e; });
  }

  /* ---------- 默认源 ---------- */
  // 影视：17 个 Apple CMS 源，原样复用网站 DIRECT_VIDEO_SEEDS（含真实 id）。
  // sort 越小越靠前/越优先。金鹰 sort 5（实测最快），非凡 sort 6（仅搜索）。
  // 量子默认禁用（kind 仍为 play，enabled=false）；暴风/非凡 kind=search（只搜不播）。
  var DEFAULT_VIDEO = [
    { id: 12, name: '金鹰资源', apiUrl: 'http://jyzyapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 5 },
    { id: 6, name: '魔都资源', apiUrl: 'https://caiji.moduapi.cc/api.php/provide/vod', kind: 'play', enabled: true, sort: 10 },
    { id: 14, name: '厂长资源', apiUrl: 'https://api.changzhang.tv/api.php/provide/vod/', kind: 'play', enabled: true, sort: 11 },
    { id: 7, name: '光速资源', apiUrl: 'https://api.guangsuapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 12 },
    { id: 15, name: '速播备用', apiUrl: 'https://subocaiji.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 13 },
    { id: 8, name: '极速资源', apiUrl: 'https://jszyapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 14 },
    { id: 16, name: '如意资源', apiUrl: 'https://cj.rycjapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 15 },
    { id: 9, name: '虎牙资源', apiUrl: 'https://www.huyaapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 16 },
    { id: 17, name: 'iKun资源', apiUrl: 'https://ikunzyapi.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 17 },
    { id: 10, name: '新狼资源', apiUrl: 'https://api.xinlangapi.com/xinlangapi.php/provide/vod', kind: 'play', enabled: true, sort: 18 },
    { id: 11, name: '360资源', apiUrl: 'https://360zy.com/api.php/provide/vod', kind: 'play', enabled: true, sort: 19 },
    { id: 1, name: '红牛资源', apiUrl: 'https://www.hongniuzy2.com/api.php/provide/vod/', kind: 'play', enabled: true, sort: 20 },
    { id: 2, name: '豪华资源', apiUrl: 'https://hhzyapi.com/api.php/provide/vod/', kind: 'play', enabled: true, sort: 21 },
    { id: 3, name: '速播资源', apiUrl: 'https://www.subozy.com/api.php/provide/vod/', kind: 'play', enabled: true, sort: 22 },
    { id: 4, name: '量子资源', apiUrl: 'https://cj.lziapi.com/api.php/provide/vod', kind: 'play', enabled: false, sort: 23 },
    { id: 5, name: '暴风资源', apiUrl: 'https://bfzyapi.com/api.php/provide/vod/', kind: 'search', enabled: true, sort: 24 },
    { id: 13, name: '非凡资源', apiUrl: 'http://ffzy5.tv/api.php/provide/vod', kind: 'search', enabled: true, sort: 6 }
  ];

  // 音乐解析器：14 个，全部免费。声明式模板，(c) 的 HaoResolvers 按模板执行。
  // qualityMap：请求音质 → 该源实际参数；缺失表示该源不支持该音质（降级链处理）。
  // urlField：取播放链接的 JSON 路径（数组 = 依次尝试；对象 = 按音质取不同字段）。
  var DEFAULT_MUSIC = [
    { key: 'huibq', name: 'Huibq', platforms: ['wy', 'tx', 'kg', 'kw', 'mg'], enabled: true, sort: 10, type: 'template',
      note: 'key 轮换，自动从 jsdelivr 取最新，失败用 share-v3',
      play: { url: 'https://lxmusicapi.onrender.com/url/{platform}/{id}/{quality}', method: 'GET',
        headers: { 'X-Request-Key': '{huibqKey}', 'User-Agent': 'lx-music-request/1.0' },
        urlField: ['url', 'data.url'], qualityMap: { hires: 'flac', lossless: 'flac' }, keyUrl: 'https://cdn.jsdelivr.net/gh/tfappstore/lx-music-source@main/huibq/latest.js', keyFallback: 'share-v3' } },
    { key: 'tang', name: 'tang（QQ FLAC）', platforms: ['tx'], enabled: true, sort: 15, type: 'template',
      play: { url: 'https://tang.api.s01s.cn/music_open_api.php?mid={id}', method: 'GET', headers: {},
        urlField: { hires: 'song_play_url_pq', lossless: 'song_play_url_sq', '320k': 'song_play_url_hq', '128k': 'song_play_url_standard' } } },
    { key: 'lzm', name: 'lzm', platforms: ['wy'], enabled: true, sort: 20, type: 'template',
      play: { url: 'https://music.lzmhhh.com/api/music/url', method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Referer': 'https://music.lzmhhh.com/' },
        body: 'id={id}&type=wy', urlField: 'data' } },
    { key: 'zddyr', name: 'zddyr', platforms: ['wy'], enabled: true, sort: 25, type: 'template',
      play: { url: 'https://yy.zddyr.top/lx/api/?source=wy&songmid={id}&quality={quality}', method: 'GET', headers: {},
        urlField: 'url', okField: 'code', okValue: 200, qualityMap: { hires: 'hires', lossless: 'flac' } } },
    { key: 'gd', name: 'GD Studio', platforms: ['wy'], enabled: true, sort: 30, type: 'template',
      play: { url: 'https://music-api.gdstudio.xyz/api.php?types=url&id={id}&source=netease&br={quality}', method: 'GET', headers: {},
        urlField: 'url', qualityMap: { hires: '999', lossless: '999', '320k': '320', '128k': '128' } } },
    { key: 'xinghai', name: '星海', platforms: ['wy', 'kg', 'kw'], enabled: true, sort: 40, type: 'template',
      note: '需先取 token（yy1.zddyr.top/lx/api/token.php，5 分钟有效，缓存 4 分钟）',
      play: { url: 'https://yy1.zddyr.top/lx/api/?source={platform}&songmid={id}&quality={quality}', method: 'GET',
        headers: { 'User-Agent': 'lx-music', 'X-Client': 'XingHaiMusicSource/v3.2.19 (Linux)', 'X-Token': '{token}' },
        urlField: 'url', okField: 'code', okValue: 200, qualityMap: { hires: 'hires', lossless: 'flac' },
        tokenUrl: 'https://yy1.zddyr.top/lx/api/token.php?device_id={deviceId}', tokenField: 'data.token',
        platformParams: { kg: '&mainHash={id}' } } },
    { key: 'oiapi_wy', name: 'oiapi-网易', platforms: ['wy'], enabled: true, sort: 60, type: 'template',
      play: { url: 'https://oiapi.net/api/Music_163?id={id}', method: 'GET', headers: {},
        urlField: 'data.0.url', okField: 'code', okValue: 0 } },
    { key: 'qjqq', name: 'qjqq', platforms: ['wy'], enabled: true, sort: 70, type: 'template',
      play: { url: 'https://metings.qjqq.cn/Song_V1', method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'url={id}&level={quality}&type=json', urlField: 'data.url',
        qualityMap: { hires: 'lossless', lossless: 'lossless', '320k': 'exhigh', '128k': 'standard' } } },
    { key: 'kangqi', name: 'kangqi', platforms: ['wy'], enabled: true, sort: 80, type: 'template',
      play: { url: 'https://ncm.kangqiovo.com/Song_V1', method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'url={id}&level={quality}&type=json', urlField: 'data.url',
        qualityMap: { hires: 'lossless', lossless: 'lossless', '320k': 'exhigh', '128k': 'standard' } } },
    { key: 'yutang', name: 'yutang', platforms: ['wy'], enabled: true, sort: 90, type: 'template',
      play: { url: 'https://api.yutangxiaowu.cn/api/music/Song_V1?url={id}&level={quality}&type=json', method: 'GET', headers: {},
        urlField: ['url', 'data.url'],
        qualityMap: { hires: 'lossless', lossless: 'lossless', '320k': 'exhigh', '128k': 'standard' } } },
    { key: 'oiapi_kw', name: 'oiapi-酷我', platforms: ['kw'], enabled: true, sort: 100, type: 'template',
      note: '按歌名搜索，需 title；br：1=无损 2=320k 3=128k',
      play: { url: 'https://oiapi.net/api/Kuwo?msg={title}&n=1&br={quality}', method: 'GET', headers: {},
        urlField: 'data.url', needsTitle: true,
        qualityMap: { hires: '1', lossless: '1', '320k': '2', '128k': '3' } } },
    { key: 'hyw', name: 'HYWmusic', platforms: ['wy'], enabled: false, sort: 110, type: 'template',
      note: '默认关闭（服务器端即为关闭状态）；固定 IP 直连',
      play: { url: 'https://103.79.184.97/api/music/url?platform=wy&source=wy&songId={id}&quality=320k', method: 'GET',
        headers: { 'X-Card-Key': '6C1F-53W0-GRKI-EVFG' }, urlField: 'url', okField: 'code', okValue: 200 } },
    { key: 'wwwweb', name: 'wwwweb', platforms: ['wy', 'kw'], enabled: true, sort: 120, type: 'template',
      play: { url: 'https://c.wwwweb.top/music/url', method: 'POST',
        headers: { 'User-Agent': 'lx-music-desktop/2.10.1', 'Content-Type': 'application/json', 'X-Api-Key': '' },
        body: '{"source":"{platform}","musicId":"{id}","quality":"{quality}"}', bodyRaw: true,
        urlField: 'url', okField: 'code', okValue: 200,
        qualityMap: { hires: 'lossless', lossless: 'flac' },
        platformQualityMap: { kw: { hires: '320k', lossless: '320k' } } } },
    { key: 'zddyr_kw', name: '星海酷我', platforms: ['kw'], enabled: true, sort: 130, type: 'template',
      note: '按歌名搜索，需 title；不支持无损/Hi-Res',
      play: { url: 'https://yy.zddyr.top/lx/api/?source=kw&name={title}&singer=&songmid={id}&interval=&albumName=&quality={quality}', method: 'GET', headers: {},
        urlField: 'url', okField: 'code', okValue: 200, needsTitle: true,
        qualityMap: { '320k': '320k', '128k': '128k' } } }
  ];

  // 直播：5 平台全开。probe 为测试用房间列表接口（只测通，不播）。
  var DEFAULT_LIVE = [
    { id: 'bili', name: '哔哩哔哩', enabled: true, sort: 10,
      probe: { url: 'https://api.live.bilibili.com/room/v1/Area/getList', method: 'GET', headers: {}, okCheck: 'code0' } },
    { id: 'douyu', name: '斗鱼', enabled: true, sort: 20,
      probe: { url: 'https://www.douyu.com/', method: 'GET', headers: {}, okCheck: 'http200' } },
    { id: 'huya', name: '虎牙', enabled: true, sort: 30,
      probe: { url: 'https://www.huya.com/', method: 'GET', headers: {}, okCheck: 'http200' } },
    { id: 'douyin', name: '抖音', enabled: true, sort: 40,
      probe: { url: 'https://live.douyin.com/webcast/feed/?aid=6383&app_name=douyin_web', method: 'GET',
        headers: { 'Referer': 'https://live.douyin.com' }, okCheck: 'http200' } },
    { id: 'ks', name: '快手', enabled: true, sort: 50,
      probe: { url: 'https://live.kuaishou.com/live_api/home/list', method: 'GET', headers: {}, okCheck: 'http200' } }
  ];

  var TEST_SONG = { id: '347230', platform: 'wy', quality: '128k', title: '七里香' }; // 测试用固定歌曲
  var QUALITY_FALLBACK = ['hires', 'lossless', '320k', '128k'];

  /* ---------- 加载 / 保存 ---------- */
  function loadList(key, defaults) {
    var raw = lsGet(key);
    if (!raw) return clone(defaults);
    try {
      var arr = JSON.parse(raw);
      if (!Array.isArray(arr) || !arr.length) return clone(defaults);
      return arr;
    } catch (e) { return clone(defaults); }
  }
  function saveList(key, list) { lsSet(key, JSON.stringify(list)); }
  function bySort(a, b) { return (a.sort || 999) - (b.sort || 999); }

  function getVideoSources() { return loadList(KEY_VIDEO, DEFAULT_VIDEO).slice().sort(bySort); }
  function getMusicResolvers() {
    return loadList(KEY_MUSIC, DEFAULT_MUSIC).slice().sort(bySort).map(function (r) {
      var c = clone(r);
      c.fn = function (songId, platform, quality, title) { return resolveWithTemplate(c, songId, platform, quality, title); };
      return c;
    });
  }
  function getLivePlatforms() { return loadList(KEY_LIVE, DEFAULT_LIVE).slice().sort(bySort); }
  function getDanmakuEndpoint() { return lsGet(KEY_DANMAKU) || ''; }
  function setDanmakuEndpoint(url) { lsSet(KEY_DANMAKU, String(url || '').trim()); return getDanmakuEndpoint(); }
  function resetAll() {
    lsDel(KEY_VIDEO); lsDel(KEY_MUSIC); lsDel(KEY_LIVE); lsDel(KEY_DANMAKU);
    return true;
  }
  function resetKind(kind) {
    if (kind === 'video') lsDel(KEY_VIDEO);
    else if (kind === 'music') lsDel(KEY_MUSIC);
    else if (kind === 'live') lsDel(KEY_LIVE);
    else return false;
    return true;
  }

  /* ---------- CRUD ---------- */
  var KIND_KEYS = { video: KEY_VIDEO, music: KEY_MUSIC, live: KEY_LIVE };
  var KIND_DEFAULTS = { video: DEFAULT_VIDEO, music: DEFAULT_MUSIC, live: DEFAULT_LIVE };
  var KIND_ID_FIELD = { video: 'id', music: 'key', live: 'id' };

  function getList(kind) {
    if (!KIND_KEYS[kind]) throw new Error('unknown kind: ' + kind);
    return loadList(KIND_KEYS[kind], KIND_DEFAULTS[kind]);
  }
  function validateDef(kind, def) {
    if (!def || typeof def !== 'object') throw new Error('源定义必须是对象');
    if (kind === 'video') {
      if (!def.name) throw new Error('影视源需要 name');
      if (!def.apiUrl || !/^https?:\/\//.test(def.apiUrl)) throw new Error('影视源需要合法的 apiUrl（http(s)://）');
      if (def.kind && def.kind !== 'play' && def.kind !== 'search') throw new Error('影视源 kind 只能是 play 或 search');
    } else if (kind === 'music') {
      if (!def.name) throw new Error('解析器需要 name');
      if (!def.play || !def.play.url) throw new Error('解析器需要 play.url 模板');
      if (def.platforms && !Array.isArray(def.platforms)) throw new Error('platforms 必须是数组，如 ["wy","kw"]');
    } else if (kind === 'live') {
      if (!def.name) throw new Error('直播平台需要 name');
      if (def.probe && def.probe.url && !/^https?:\/\//.test(def.probe.url)) throw new Error('probe.url 须为 http(s)://');
    }
  }
  function addSource(kind, def) {
    validateDef(kind, def);
    var list = getList(kind);
    var idField = KIND_ID_FIELD[kind];
    var d = clone(def);
    if (d[idField] == null || d[idField] === '') d[idField] = uid(kind === 'music' ? 'r' : 's');
    if (list.some(function (x) { return String(x[idField]) === String(d[idField]); })) {
      throw new Error('已存在相同 id/key：' + d[idField]);
    }
    if (d.enabled == null) d.enabled = true;
    if (d.sort == null) d.sort = 100 + list.length;
    if (kind === 'video' && !d.kind) d.kind = 'play';
    list.push(d);
    saveList(KIND_KEYS[kind], list);
    return clone(d);
  }
  function updateSource(kind, id, def) {
    validateDef(kind, Object.assign({}, getList(kind).filter(function (x) { return String(x[KIND_ID_FIELD[kind]]) === String(id); })[0] || {}, def));
    var list = getList(kind);
    var idField = KIND_ID_FIELD[kind];
    var idx = -1;
    list.forEach(function (x, i) { if (String(x[idField]) === String(id)) idx = i; });
    if (idx < 0) throw new Error('找不到源：' + id);
    var merged = Object.assign({}, list[idx], clone(def));
    merged[idField] = list[idx][idField]; // id/key 不可改
    list[idx] = merged;
    saveList(KIND_KEYS[kind], list);
    return clone(merged);
  }
  function deleteSource(kind, id) {
    var list = getList(kind);
    var idField = KIND_ID_FIELD[kind];
    // 影视源不可删到零个：至少保留一个（提示由调用方展示）
    if (kind === 'video' && list.length <= 1) {
      return { ok: false, error: '至少保留一个影视源，不能全部删除（可先添加新源再删旧源）' };
    }
    var next = list.filter(function (x) { return String(x[idField]) !== String(id); });
    if (next.length === list.length) return { ok: false, error: '找不到源：' + id };
    saveList(KIND_KEYS[kind], next);
    return { ok: true };
  }
  function setSourceEnabled(kind, id, enabled) {
    return updateSource(kind, id, { enabled: !!enabled });
  }

  /* ---------- 模板执行（供 (c) HaoResolvers 调用；testSource 也用它） ---------- */
  var _huibqKey = '', _huibqKeyAt = 0;
  function getHuibqKey(def) {
    var p = (def && def.play) || {};
    if (_huibqKey && Date.now() - _huibqKeyAt < 3600000) return Promise.resolve(_huibqKey);
    if (!p.keyUrl) return Promise.resolve(p.keyFallback || 'share-v3');
    return haoFetch(p.keyUrl, {}, 8000).then(function (r) {
      var m = String(r.text || '').match(/API_KEY\s*=\s*['"]([^'"]+)['"]/);
      if (m && m[1]) { _huibqKey = m[1]; _huibqKeyAt = Date.now(); return _huibqKey; }
      return p.keyFallback || 'share-v3';
    }).catch(function () { return p.keyFallback || 'share-v3'; });
  }
  var _xhToken = '', _xhTokenAt = 0, _xhDevice = 'lx-sa-' + Math.random().toString(36).slice(2, 10);
  function getXhToken(def) {
    var p = (def && def.play) || {};
    if (_xhToken && Date.now() - _xhTokenAt < 240000) return Promise.resolve(_xhToken);
    if (!p.tokenUrl) return Promise.resolve('');
    return haoFetch(fillTpl(p.tokenUrl, { deviceId: _xhDevice }), { headers: { 'User-Agent': 'lx-music' } }, 6000)
      .then(function (r) {
        var tk = getPath(r.json, p.tokenField || 'data.token') || '';
        if (tk) { _xhToken = tk; _xhTokenAt = Date.now(); }
        return tk;
      }).catch(function () { return ''; });
  }
  function mapQuality(def, platform, quality) {
    var p = (def && def.play) || {};
    if (p.platformQualityMap && p.platformQualityMap[platform] && p.platformQualityMap[platform][quality] != null) {
      return p.platformQualityMap[platform][quality];
    }
    if (p.qualityMap && p.qualityMap[quality] != null) return p.qualityMap[quality];
    return quality;
  }
  function pickUrlField(def, quality, json) {
    var uf = def.play && def.play.urlField;
    if (!uf) return '';
    if (typeof uf === 'string') return getPath(json, uf) || '';
    if (Array.isArray(uf)) {
      for (var i = 0; i < uf.length; i++) { var v = getPath(json, uf[i]); if (v) return v; }
      return '';
    }
    if (typeof uf === 'object') {
      var f = uf[quality] || uf['320k'] || uf['128k'] || '';
      return f ? (getPath(json, f) || '') : '';
    }
    return '';
  }
  // 按模板解析一条播放链接。返回 Promise<string>（空串 = 解析失败）。
  function resolveWithTemplate(def, songId, platform, quality, title) {
    var p = def.play || {};
    platform = platform || 'wy';
    quality = quality || '320k';
    if (p.needsTitle && !title) return Promise.resolve('');
    var q = mapQuality(def, platform, quality);
    if (q == null || q === '') return Promise.resolve(''); // 该源不支持此音质
    var vars = { id: songId, platform: platform, quality: q, title: title || songId, keyword: title || songId, limit: 20 };
    var headers = {};
    Object.keys(p.headers || {}).forEach(function (hk) { headers[hk] = p.headers[hk]; });
    var needKey = Object.keys(headers).some(function (hk) { return String(headers[hk]).indexOf('{huibqKey}') >= 0; }) || String(p.url).indexOf('{huibqKey}') >= 0;
    var needToken = Object.keys(headers).some(function (hk) { return String(headers[hk]).indexOf('{token}') >= 0; });
    return Promise.resolve()
      .then(function () { return needKey ? getHuibqKey(def) : ''; })
      .then(function (hk) {
        if (hk) {
          Object.keys(headers).forEach(function (k) { headers[k] = String(headers[k]).replace('{huibqKey}', hk); });
          vars.huibqKey = hk;
        }
        return needToken ? getXhToken(def) : '';
      })
      .then(function (tk) {
        if (needToken) {
          if (!tk) return '';
          Object.keys(headers).forEach(function (k) { headers[k] = String(headers[k]).replace('{token}', tk); });
          vars.token = tk;
        }
        var url = fillTpl(p.url, vars);
        if (p.platformParams && p.platformParams[platform]) url += fillTpl(p.platformParams[platform], vars);
        var body = null;
        if (p.body != null) body = p.bodyRaw ? fillRaw(p.body, vars) : fillTpl(p.body, vars);
        return haoFetch(url, { method: p.method || 'GET', headers: headers, body: body }, 8000);
      })
      .then(function (r) {
        if (!r || (r.status && r.status >= 400)) return '';
        var j = r.json;
        if (p.okField != null && p.okValue != null && j && getPath(j, p.okField) !== p.okValue) return '';
        var u = pickUrlField(def, quality, j);
        if (!u || typeof u !== 'string') return '';
        return u.indexOf('http') === 0 ? u : ('https:' + u.replace(/^https?:/, ''));
      })
      .catch(function () { return ''; });
  }

  /* ---------- 测试 ---------- */
  function timed(promise) {
    var t0 = Date.now();
    return Promise.resolve(promise).then(function (v) { return { value: v, ms: Date.now() - t0 }; });
  }
  function testSource(kind, def) {
    var t0 = Date.now();
    var done = function (ok, info, error) { return { ok: ok, ms: Date.now() - t0, info: info, error: error }; };
    try { validateDef(kind, def || {}); } catch (e) { return Promise.resolve(done(false, null, e.message)); }
    if (kind === 'video') {
      var base = String(def.apiUrl).replace(/\/$/, '');
      return haoFetch(base + '?ac=videolist&pg=1', { headers: { 'User-Agent': 'Mozilla/5.0' } }, 10000)
        .then(function (r) {
          var j = r.json;
          if (r.status && r.status >= 400) return done(false, null, 'HTTP ' + r.status);
          if (j && (Array.isArray(j.list) || Array.isArray(j.class))) {
            return done(true, '连通，返回 ' + (j.list ? j.list.length : j.class.length) + ' 条（' + (j.list ? '影片列表' : '分类') + '），共 ' + (j.total != null ? j.total : '?') + ' 条', null);
          }
          if (j && j.code === 0) return done(true, '连通（返回 code 0）', null);
          return done(false, null, '返回内容不是 Apple CMS 格式');
        })
        .catch(function (e) { return done(false, null, '连接失败：' + (e && e.message ? e.message : e)); });
    }
    if (kind === 'music') {
      var d = clone(def);
      if (!d.play) return Promise.resolve(done(false, null, '缺少 play 模板'));
      return timed(resolveWithTemplate(d, TEST_SONG.id, (d.platforms && d.platforms[0]) || 'wy', TEST_SONG.quality, TEST_SONG.title))
        .then(function (r) {
          if (r.value) return done(true, '解析成功：' + r.value.slice(0, 80) + (r.value.length > 80 ? '…' : ''), null);
          return done(false, null, '解析失败：未返回播放链接（可能该源失效或不支持测试歌曲）');
        });
    }
    if (kind === 'live') {
      var probe = def.probe || { url: 'https://www.google.com/', okCheck: 'http200' };
      if (!probe.url) return Promise.resolve(done(false, null, '该平台未配置测试地址'));
      return haoFetch(probe.url, { method: probe.method || 'GET', headers: probe.headers || {} }, 10000)
        .then(function (r) {
          if (probe.okCheck === 'code0') {
            if (r.json && r.json.code === 0) return done(true, '连通（code 0）', null);
            return done(false, null, '返回 code 不是 0');
          }
          if (r.status === 200 || r.ok) return done(true, '连通（HTTP 200）', null);
          return done(false, null, 'HTTP ' + r.status);
        })
        .catch(function (e) { return done(false, null, '连接失败：' + (e && e.message ? e.message : e)); });
    }
    if (kind === 'danmaku') {
      var ep = String((def && def.url) || getDanmakuEndpoint() || '');
      if (!ep) return Promise.resolve(done(false, null, '未配置弹幕端点'));
      return haoFetch(ep.replace(/\/$/, '') + '/api/video/ext-danmaku?vid=1', {}, 8000)
        .then(function (r) { return r.status === 200 || r.ok ? done(true, '弹幕端点连通', null) : done(false, null, 'HTTP ' + r.status); })
        .catch(function (e) { return done(false, null, '连接失败：' + (e && e.message ? e.message : e)); });
    }
    return Promise.resolve(done(false, null, '未知 kind：' + kind));
  }

  /* ---------- 导入 / 导出 ---------- */
  var SOURCE_FORMAT = 'haomusic-source/1';
  // 声明式 JSON 源格式（见 SPEC.md）：
  // {format:'haomusic-source/1', id, name, author, version, description,
  //  platforms:{wy:{name, actions:['musicUrl','search','lyric'], qualities:[...],
  //   defaultQuality, qualityMap, qualityFallback,
  //   search:{url,method,resultList,fields}, play:{url,method,urlField,headers},
  //   lyric:{url,lyricField}}}}
  function normalizeImported(obj) {
    if (!obj || typeof obj !== 'object') throw new Error('导入内容不是 JSON 对象');
    // A. 标准格式 haomusic-source/1
    if (obj.format === SOURCE_FORMAT) {
      if (!obj.name) throw new Error('源缺少 name');
      var plats = obj.platforms || {};
      var keys = Object.keys(plats);
      if (!keys.length) throw new Error('源没有声明任何平台（platforms 为空）');
      var first = plats[keys[0]];
      if (!first.play || !first.play.url) throw new Error('平台 ' + keys[0] + ' 缺少 play.url');
      // 取第一个平台的 play 模板作为主模板；其余平台的 play/search/lyric 保留在 platforms 字段供 (c) 使用
      var play = first.play;
      var def = {
        key: obj.id || uid('r'), name: obj.name, author: obj.author || '', version: obj.version || '',
        description: obj.description || '', platforms: keys, enabled: true, sort: 200,
        type: 'json-source', format: SOURCE_FORMAT, sourceJson: clone(obj),
        play: {
          url: play.url, method: play.method || 'GET', headers: play.headers || {},
          body: play.body || null, bodyRaw: !!play.bodyRaw, urlField: play.urlField || 'url',
          qualityMap: first.qualityMap || {}, okField: play.okField, okValue: play.okValue,
          needsTitle: !!(first.play && first.play.needsTitle)
        }
      };
      if (first.defaultQuality) def.play.defaultQuality = first.defaultQuality;
      return { kind: 'music', def: def };
    }
    // B. 裸定义：直接就是一条影视源 / 解析器 / 直播平台
    if (obj.apiUrl) return { kind: 'video', def: { id: obj.id, name: obj.name, apiUrl: obj.apiUrl, kind: obj.kind || 'play', enabled: obj.enabled !== false, sort: obj.sort || 100 } };
    if (obj.play && obj.play.url) return { kind: 'music', def: { key: obj.key || obj.id, name: obj.name, platforms: obj.platforms || ['wy'], enabled: obj.enabled !== false, sort: obj.sort || 200, type: 'json-source', play: obj.play } };
    if (obj.probe && obj.probe.url) return { kind: 'live', def: { id: obj.id, name: obj.name, enabled: obj.enabled !== false, sort: obj.sort || 100, probe: obj.probe } };
    // C. 完整备份文件：{format:'hao-sa-backup/1', video:[...], music:[...], live:[...]}
    if (obj.format === 'hao-sa-backup/1') return { kind: 'backup', def: obj };
    throw new Error('无法识别的源格式：需要 haomusic-source/1，或含 apiUrl / play.url / probe.url 的源定义');
  }
  function parseSourceText(text) {
    var t = String(text || '').trim();
    if (!t) throw new Error('导入内容为空');
    var obj;
    try { obj = JSON.parse(t); } catch (e) { throw new Error('不是合法 JSON：' + e.message); }
    return normalizeImported(obj);
  }
  function importSourceText(text) {
    var parsed = parseSourceText(text);
    if (parsed.kind === 'backup') return importBackup(parsed.def);
    var added = addSource(parsed.kind, parsed.def);
    return { kind: parsed.kind, def: added };
  }
  function importSourceUrl(url) {
    if (!/^https?:\/\//.test(String(url || ''))) return Promise.reject(new Error('URL 须以 http(s):// 开头'));
    return haoFetch(String(url), {}, 15000).then(function (r) {
      if (r.status && r.status >= 400) throw new Error('下载失败：HTTP ' + r.status);
      return importSourceText(r.text || '');
    });
  }
  // 浏览器 File 对象；Node 下传字符串亦可
  function importSourceFile(file) {
    if (typeof file === 'string') return Promise.resolve().then(function () { return importSourceText(file); });
    return new Promise(function (resolve, reject) {
      try {
        var reader = new FileReader();
        reader.onload = function () { try { resolve(importSourceText(String(reader.result || ''))); } catch (e) { reject(e); } };
        reader.onerror = function () { reject(new Error('读取文件失败')); };
        reader.readAsText(file);
      } catch (e) { reject(e); }
    });
  }
  // (c) 线的解析器缓存键（Huibq key + 星海设备 id）也随源备份走，
  // 否则恢复后 Huibq/星海要重新取 key。只导出这三个白名单键。
  var BACKUP_KEY_NAMES = ['hao_sa_huibq_key', 'hao_sa_huibq_key_at', 'hao_sa_xh_device'];
  function exportAll() {
    var keys = {};
    BACKUP_KEY_NAMES.forEach(function (k) { var v = lsGet(k); if (v !== null) keys[k] = v; });
    return JSON.stringify({
      format: 'hao-sa-backup/1', app: 'HAo Studio', exportedAt: new Date().toISOString(), version: 1,
      video: getVideoSources(), music: loadList(KEY_MUSIC, DEFAULT_MUSIC), live: getLivePlatforms(),
      danmakuEndpoint: getDanmakuEndpoint(), keys: keys
    }, null, 2);
  }
  function importBackup(obj) {
    if (!obj || obj.format !== 'hao-sa-backup/1') throw new Error('不是 HAo Studio 源备份文件');
    var counts = { video: 0, music: 0, live: 0 };
    ['video', 'music', 'live'].forEach(function (kind) {
      var arr = obj[kind];
      if (Array.isArray(arr) && arr.length) {
        arr.forEach(function (d) { try { validateDef(kind, d); } catch (e) { throw new Error('备份中 ' + kind + ' 源无效：' + e.message); } });
        saveList(KIND_KEYS[kind], clone(arr));
        counts[kind] = arr.length;
      }
    });
    if (typeof obj.danmakuEndpoint === 'string') setDanmakuEndpoint(obj.danmakuEndpoint);
    if (obj.keys && typeof obj.keys === 'object') {
      BACKUP_KEY_NAMES.forEach(function (k) { if (typeof obj.keys[k] === 'string') lsSet(k, obj.keys[k]); });
    }
    return { kind: 'backup', counts: counts };
  }
  function downloadExport() {
    if (typeof document === 'undefined' || typeof Blob === 'undefined') return exportAll();
    var blob = new Blob([exportAll()], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'hao-studio-sources-' + new Date().toISOString().slice(0, 10) + '.json';
    document.body.appendChild(a); a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
    return true;
  }

  /* ---------- LX Music JS 源脚本导入（只解析声明，不执行代码） ---------- */
  // LX Music / 歌一刀源脚本结构：头部注释 @name/@version/@author，
  // 代码内 send('inited' / EVENT_NAMES.inited, { sources: { wy: { name, actions, qualities... } } })。
  // 本函数只做文本解析：提取元信息 + inited 声明对象；解析失败则明确报错，绝不静默失败、不 eval。
  function extractBalancedObject(code, startIdx) {
    var i = code.indexOf('{', startIdx);
    if (i < 0) return null;
    var depth = 0, inStr = null, escNext = false;
    for (var j = i; j < code.length; j++) {
      var ch = code[j];
      if (escNext) { escNext = false; continue; }
      if (inStr) {
        if (ch === '\\') escNext = true;
        else if (ch === inStr) inStr = null;
        continue;
      }
      if (ch === '"' || ch === "'" || ch === '`') { inStr = ch; continue; }
      if (ch === '{') depth++;
      else if (ch === '}') { depth--; if (depth === 0) return code.slice(i, j + 1); }
    }
    return null;
  }
  function jsObjToJson(text) {
    // 仅处理“声明式对象字面量”：去注释、单引号→双引号、键加引号、去尾逗号
    var s = String(text).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
    s = s.replace(/'([^'\\]*(?:\\.[^'\\]*)*)'/g, function (m, inner) {
      return '"' + inner.replace(/\\'/g, "'").replace(/"/g, '\\"') + '"';
    });
    s = s.replace(/([{,]\s*)([A-Za-z_$][\w$]*)(\s*:)/g, '$1"$2"$3');
    s = s.replace(/,(\s*[}\]])/g, '$1');
    return JSON.parse(s);
  }
  function parseLxSourceScript(code) {
    var src = String(code || '');
    if (!src.trim()) throw new Error('脚本内容为空');
    var meta = {};
    var mm;
    var metaRe = /^\s*(?:\/\/|\*)\s*@(\w+)\s+(.+?)\s*$/gm;
    while ((mm = metaRe.exec(src)) !== null) meta[mm[1]] = mm[2];
    var name = meta.name || meta.title || '';
    if (!name) throw new Error('无法解析：脚本头部缺少 @name 元信息（不是 LX Music 兼容源脚本）');
    // 找 inited 声明：send('inited', {...}) / send(EVENT_NAMES.inited, {...}) / .inited, {...}
    var idx = src.search(/inited['"]?\s*,\s*\{/);
    if (idx < 0) throw new Error('无法解析：脚本中未找到 send(inited, {...}) 平台声明，无法安全导入（不执行任意代码）');
    var objText = extractBalancedObject(src, idx);
    if (!objText) throw new Error('无法解析：inited 声明对象括号不匹配');
    var declared;
    try { declared = jsObjToJson(objText); } catch (e) {
      throw new Error('无法解析：inited 声明不是纯声明式对象（' + e.message + '），请改用 JSON 格式导入');
    }
    var sources = declared.sources || declared;
    var plats = Object.keys(sources || {});
    if (!plats.length) throw new Error('无法解析：inited 声明中没有 sources 平台');
    var firstKey = plats[0];
    var first = sources[firstKey] || {};
    var actions = first.actions || first.action || [];
    // 声明式导入只取“可静态描述”的部分；含函数/动态逻辑的源无法用 JSON 模板表达，明确报错
    var playUrl = null;
    if (typeof first.musicUrl === 'string') playUrl = first.musicUrl;
    else if (first.api && typeof first.api.musicUrl === 'string') playUrl = first.api.musicUrl;
    if (!playUrl) {
      throw new Error('该脚本的播放链接需要执行 JS 逻辑才能得到（未找到静态 musicUrl 声明），JSON 模板无法表达；请改用 haomusic-source/1 JSON 格式手动填写 play.url');
    }
    var qualities = Array.isArray(first.qualities) ? first.qualities.map(function (q) { return typeof q === 'string' ? q : (q && q.type) || ''; }).filter(Boolean) : [];
    var def = {
      key: uid('lx'), name: name, author: meta.author || '', version: meta.version || '',
      description: meta.description || ('由 LX Music 脚本导入（仅解析声明，未执行脚本）'),
      platforms: plats, enabled: true, sort: 210, type: 'lx-script',
      lxMeta: { name: name, version: meta.version || '', author: meta.author || '', actions: actions, qualities: qualities },
      play: { url: playUrl, method: 'GET', headers: {}, urlField: 'url', qualityMap: {} }
    };
    return { kind: 'music', def: def, meta: meta, platforms: plats, actions: actions, qualities: qualities };
  }
  function importLxScript(code) {
    var parsed = parseLxSourceScript(code);
    var added = addSource('music', parsed.def);
    return { kind: 'music', def: added, platforms: parsed.platforms, actions: parsed.actions, qualities: parsed.qualities };
  }

  /* ---------- 三语词条（(a) 并入 app.js 的 I18N；key 前缀 src） ---------- */
  var I18N = {
    zh: { srcTitle: '源管理', srcVideo: '影视源', srcMusic: '音乐解析器', srcLive: '直播平台', srcOther: '其他设置',
      srcAdd: '新增', srcEdit: '编辑', srcDel: '删除', srcTest: '测试', srcEnable: '启用', srcDisable: '停用',
      srcName: '名称', srcApiUrl: '接口地址', srcKind: '类型', srcKindPlay: '播放+搜索', srcKindSearch: '仅搜索',
      srcPlatforms: '平台（wy 网易 / tx QQ / kg 酷狗 / kw 酷我 / mg 咪咕，逗号分隔）',
      srcPlayUrl: '播放链接模板（可用 {platform} {id} {quality} {title}）',
      srcSave: '保存', srcCancel: '取消', srcImport: '导入', srcExport: '导出备份', srcImportBackup: '导入备份',
      srcPasteJson: '粘贴 JSON（单个源或完整备份）', srcPasteUrl: '或粘贴源 URL（.json）', srcPickFile: '或选择 .json 文件',
      srcTestOk: '测试通过', srcTestFail: '测试失败', srcDeleted: '已删除', srcSaved: '已保存', srcImported: '导入成功',
      srcKeepOne: '至少保留一个影视源', srcDanmaku: '弹幕端点（默认空 = 仅 Bilibili 直连）',
      srcDanmakuPh: '如 https://你的域名（留空则不连服务器）',
      srcBackupTip: '源存在本机，重装 App 会丢失；请定期导出备份。', srcLxNote: 'LX Music 脚本仅解析声明，不执行代码；解析失败会明确报错。',
      srcConfirmDel: '确定删除该源吗？', srcNoSources: '暂无源', srcSort: '排序', srcEnabled: '已启用', srcDisabled: '已停用' },
    tw: { srcTitle: '源管理', srcVideo: '影視源', srcMusic: '音樂解析器', srcLive: '直播平台', srcOther: '其他設定',
      srcAdd: '新增', srcEdit: '編輯', srcDel: '刪除', srcTest: '測試', srcEnable: '啟用', srcDisable: '停用',
      srcName: '名稱', srcApiUrl: '介面位址', srcKind: '類型', srcKindPlay: '播放+搜尋', srcKindSearch: '僅搜尋',
      srcPlatforms: '平台（wy 網易 / tx QQ / kg 酷狗 / kw 酷我 / mg 咪咕，逗號分隔）',
      srcPlayUrl: '播放連結範本（可用 {platform} {id} {quality} {title}）',
      srcSave: '儲存', srcCancel: '取消', srcImport: '匯入', srcExport: '匯出備份', srcImportBackup: '匯入備份',
      srcPasteJson: '貼上 JSON（單個源或完整備份）', srcPasteUrl: '或貼上源 URL（.json）', srcPickFile: '或選擇 .json 檔案',
      srcTestOk: '測試通過', srcTestFail: '測試失敗', srcDeleted: '已刪除', srcSaved: '已儲存', srcImported: '匯入成功',
      srcKeepOne: '至少保留一個影視源', srcDanmaku: '彈幕端點（預設空 = 僅 Bilibili 直連）',
      srcDanmakuPh: '如 https://你的網域（留空則不連伺服器）',
      srcBackupTip: '源存在本機，重裝 App 會遺失；請定期匯出備份。', srcLxNote: 'LX Music 腳本僅解析宣告，不執行程式碼；解析失敗會明確報錯。',
      srcConfirmDel: '確定刪除該源嗎？', srcNoSources: '暫無源', srcSort: '排序', srcEnabled: '已啟用', srcDisabled: '已停用' },
    en: { srcTitle: 'Sources', srcVideo: 'Video sources', srcMusic: 'Music resolvers', srcLive: 'Live platforms', srcOther: 'Other settings',
      srcAdd: 'Add', srcEdit: 'Edit', srcDel: 'Delete', srcTest: 'Test', srcEnable: 'Enable', srcDisable: 'Disable',
      srcName: 'Name', srcApiUrl: 'API URL', srcKind: 'Type', srcKindPlay: 'Play + search', srcKindSearch: 'Search only',
      srcPlatforms: 'Platforms (wy NetEase / tx QQ / kg Kugou / kw Kuwo / mg Migu, comma separated)',
      srcPlayUrl: 'Play URL template ({platform} {id} {quality} {title})',
      srcSave: 'Save', srcCancel: 'Cancel', srcImport: 'Import', srcExport: 'Export backup', srcImportBackup: 'Import backup',
      srcPasteJson: 'Paste JSON (one source or full backup)', srcPasteUrl: 'Or paste a source URL (.json)', srcPickFile: 'Or pick a .json file',
      srcTestOk: 'Test passed', srcTestFail: 'Test failed', srcDeleted: 'Deleted', srcSaved: 'Saved', srcImported: 'Imported',
      srcKeepOne: 'Keep at least one video source', srcDanmaku: 'Danmaku endpoint (empty = Bilibili direct only)',
      srcDanmakuPh: 'e.g. https://your-domain (empty = no server)',
      srcBackupTip: 'Sources live on this device and are lost on reinstall; export a backup regularly.', srcLxNote: 'LX Music scripts are parsed for declarations only, never executed; parse failures report an explicit error.',
      srcConfirmDel: 'Delete this source?', srcNoSources: 'No sources', srcSort: 'Sort', srcEnabled: 'Enabled', srcDisabled: 'Disabled' }
  };
  function lang() {
    try {
      if (typeof root.__haoLang === 'string') return root.__haoLang;
      if (root.localStorage) { var l = root.localStorage.getItem('hao_lang') || root.localStorage.getItem('lang'); if (l) return l; }
    } catch (e) {}
    return 'zh';
  }
  function t(key) {
    var l = lang();
    var dict = I18N[l] || I18N.zh;
    if (typeof root.t === 'function') { try { var v = root.t(key); if (v && v !== key) return v; } catch (e) {} }
    return dict[key] || I18N.zh[key] || key;
  }

  /* ---------- UI：源管理页（复用 style.css 的 card / lp-sheet / lp-box / ghost-btn） ---------- */
  var _tab = 'video';
  var _container = null;
  function rowHtml(kind, item) {
    var idField = KIND_ID_FIELD[kind];
    var id = item[idField];
    var sub = kind === 'video' ? esc(item.apiUrl || '') + ' · ' + (item.kind === 'search' ? t('srcKindSearch') : t('srcKindPlay'))
      : kind === 'music' ? esc((item.platforms || []).join(', ')) + (item.type === 'lx-script' ? ' · LX' : item.type === 'json-source' ? ' · JSON' : '') + (item.lxMeta && item.lxMeta.version ? ' · v' + esc(String(item.lxMeta.version)) : (item.version ? ' · v' + esc(String(item.version)) : '')) + (item.lxMeta && item.lxMeta.author ? ' · ' + esc(String(item.lxMeta.author)) : (item.author ? ' · ' + esc(String(item.author)) : ''))
      : esc(item.id || '');
    return '<div class="card" data-kind="' + kind + '" data-id="' + esc(String(id)) + '" style="display:flex;align-items:center;gap:10px;padding:12px 14px;margin:8px 0">'
      + '<div style="flex:1;min-width:0"><div style="font-weight:600">' + esc(item.name || '') + '</div>'
      + '<div style="font-size:12px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + sub + '</div></div>'
      + '<span style="font-size:12px;color:var(--muted)">' + (item.enabled ? t('srcEnabled') : t('srcDisabled')) + '</span>'
      + '<button class="ghost-btn" data-act="toggle">' + (item.enabled ? t('srcDisable') : t('srcEnable')) + '</button>'
      + '<button class="ghost-btn" data-act="test">' + t('srcTest') + '</button>'
      + '<button class="ghost-btn" data-act="edit">' + t('srcEdit') + '</button>'
      + '<button class="ghost-btn" data-act="del" style="color:var(--accent)">' + t('srcDel') + '</button></div>';
  }
  function renderSourcesPage(container) {
    if (typeof document === 'undefined') return '';
    _container = container || document.getElementById('sourcesPage') || document.body;
    var tabs = ['video', 'music', 'live', 'other'];
    var tabNames = { video: t('srcVideo'), music: t('srcMusic'), live: t('srcLive'), other: t('srcOther') };
    var html = '<div class="sources-page"><h2 style="margin:4px 0 10px">' + t('srcTitle') + '</h2>'
      + '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:6px">'
      + tabs.map(function (k) { return '<button class="ghost-btn" data-tab="' + k + '" style="' + (_tab === k ? 'border-color:var(--accent);color:var(--accent)' : '') + '">' + tabNames[k] + '</button>'; }).join('')
      + '</div>'
      + '<div style="display:flex;gap:8px;flex-wrap:wrap;margin:6px 0 4px">'
      + '<button class="ghost-btn" data-act="add">＋ ' + t('srcAdd') + '</button>'
      + '<button class="ghost-btn" data-act="import">' + t('srcImport') + '</button>'
      + '<button class="ghost-btn" data-act="export">' + t('srcExport') + '</button>'
      + '<button class="ghost-btn" data-act="reset">' + t('srcImportBackup') + '</button></div>';
    if (_tab === 'video') html += getVideoSources().map(function (s) { return rowHtml('video', s); }).join('') || '<p>' + t('srcNoSources') + '</p>';
    else if (_tab === 'music') html += getMusicResolvers().map(function (s) { return rowHtml('music', s); }).join('') || '<p>' + t('srcNoSources') + '</p>';
    else if (_tab === 'live') html += getLivePlatforms().map(function (s) { return rowHtml('live', s); }).join('') || '<p>' + t('srcNoSources') + '</p>';
    else {
      html += '<div class="card" style="padding:14px;margin:8px 0"><label style="font-size:13px">' + t('srcDanmaku') + '</label>'
        + '<input id="haoDanmaku" type="text" value="' + esc(getDanmakuEndpoint()) + '" placeholder="' + esc(t('srcDanmakuPh')) + '" style="width:100%;margin:6px 0;padding:10px;border-radius:10px;border:1px solid var(--border);background:var(--bg)"/>'
        + '<button class="ghost-btn" data-act="saveOther">' + t('srcSave') + '</button></div>';
    }
    html += '<p style="font-size:12px;color:var(--muted)">' + t('srcBackupTip') + ' ' + t('srcLxNote') + '</p></div>';
    _container.innerHTML = html;
    bindSourcesPage(_container);
    return html;
  }
  function toast(msg) {
    if (typeof root.showToast === 'function') { root.showToast(msg); return; }
    if (typeof document !== 'undefined') {
      var el = document.createElement('div');
      el.textContent = msg;
      el.style.cssText = 'position:fixed;left:50%;bottom:80px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 16px;border-radius:999px;z-index:10010;font-size:14px';
      document.body.appendChild(el);
      setTimeout(function () { el.remove(); }, 2500);
    }
  }
  function openSheet(html) {
    var old = document.getElementById('haoSrcSheet');
    if (old) old.remove();
    var sheet = document.createElement('div');
    sheet.className = 'lp-sheet'; sheet.id = 'haoSrcSheet';
    sheet.style.display = 'flex';
    sheet.innerHTML = '<div class="lp-box">' + html + '</div>';
    sheet.addEventListener('click', function (e) { if (e.target === sheet) sheet.remove(); });
    document.body.appendChild(sheet);
    return sheet;
  }
  function closeSheet() { var s = document.getElementById('haoSrcSheet'); if (s) s.remove(); }
  function field(label, id, value, ph) {
    return '<label style="font-size:13px;text-align:left">' + label + '</label>'
      + '<input id="' + id + '" type="text" value="' + esc(value || '') + '" placeholder="' + esc(ph || '') + '" style="width:100%;padding:10px;border-radius:10px;border:1px solid var(--border);background:var(--bg)"/>';
  }
  function openSourceEditor(kind, id) {
    var item = null;
    if (id != null) {
      var list = getList(kind);
      var idField = KIND_ID_FIELD[kind];
      list.forEach(function (x) { if (String(x[idField]) === String(id)) item = x; });
    }
    var isNew = !item;
    var html = '<h3 style="margin:0 0 6px">' + (isNew ? t('srcAdd') : t('srcEdit')) + ' · ' + t(kind === 'video' ? 'srcVideo' : kind === 'music' ? 'srcMusic' : 'srcLive') + '</h3>'
      + field(t('srcName'), 'haoF_name', item && item.name, '');
    if (kind === 'video') {
      html += field(t('srcApiUrl'), 'haoF_apiUrl', item && item.apiUrl, 'https://…/api.php/provide/vod')
        + '<label style="font-size:13px;text-align:left">' + t('srcKind') + '</label>'
        + '<select id="haoF_kind" style="width:100%;padding:10px;border-radius:10px;border:1px solid var(--border);background:var(--bg)">'
        + '<option value="play"' + (!item || item.kind === 'play' ? ' selected' : '') + '>' + t('srcKindPlay') + '</option>'
        + '<option value="search"' + (item && item.kind === 'search' ? ' selected' : '') + '>' + t('srcKindSearch') + '</option></select>';
    } else if (kind === 'music') {
      html += field(t('srcPlatforms'), 'haoF_platforms', item ? (item.platforms || []).join(',') : 'wy', 'wy, kw')
        + field(t('srcPlayUrl'), 'haoF_playUrl', item && item.play && item.play.url, 'https://…/{platform}/{id}/{quality}')
        + field('urlField（JSON 路径，如 data.url）', 'haoF_urlField', item && item.play && (typeof item.play.urlField === 'string' ? item.play.urlField : ''), 'url');
    } else {
      html += field(t('srcApiUrl') + '（测试地址，可空）', 'haoF_probe', item && item.probe && item.probe.url, 'https://…');
    }
    html += field(t('srcSort'), 'haoF_sort', item ? item.sort : '', '10')
      + '<div style="display:flex;gap:8px"><button class="ghost-btn" id="haoF_save" style="flex:1;border-color:var(--accent);color:var(--accent)">' + t('srcSave') + '</button>'
      + '<button class="ghost-btn" id="haoF_cancel" style="flex:1">' + t('srcCancel') + '</button></div>';
    var sheet = openSheet(html);
    sheet.querySelector('#haoF_cancel').addEventListener('click', closeSheet);
    sheet.querySelector('#haoF_save').addEventListener('click', function () {
      try {
        var val = function (i) { var e = sheet.querySelector('#' + i); return e ? e.value.trim() : ''; };
        var def = { name: val('haoF_name'), enabled: item ? !!item.enabled : true, sort: parseInt(val('haoF_sort'), 10) || 100 };
        if (kind === 'video') def = Object.assign(def, { apiUrl: val('haoF_apiUrl'), kind: val('haoF_kind') || 'play' });
        else if (kind === 'music') {
          def.platforms = val('haoF_platforms').split(',').map(function (s) { return s.trim(); }).filter(Boolean);
          def.play = Object.assign({}, item && item.play, { url: val('haoF_playUrl'), method: 'GET', headers: {}, urlField: val('haoF_urlField') || 'url' });
        } else def.probe = { url: val('haoF_probe'), method: 'GET', headers: {}, okCheck: 'http200' };
        if (isNew) addSource(kind, def); else updateSource(kind, id, def);
        closeSheet(); toast(t('srcSaved')); renderSourcesPage(_container);
      } catch (e) { toast(e.message); }
    });
  }
  function openImportDialog() {
    var html = '<h3 style="margin:0 0 6px">' + t('srcImport') + '</h3>'
      + '<textarea id="haoI_text" rows="6" placeholder="' + esc(t('srcPasteJson')) + '" style="width:100%;padding:10px;border-radius:10px;border:1px solid var(--border);background:var(--bg)"></textarea>'
      + '<input id="haoI_url" type="text" placeholder="' + esc(t('srcPasteUrl')) + '" style="width:100%;padding:10px;border-radius:10px;border:1px solid var(--border);background:var(--bg)"/>'
      + '<input id="haoI_file" type="file" accept=".json,.js,application/json" style="width:100%"/>'
      + '<p style="font-size:12px;color:var(--muted);margin:0">' + t('srcLxNote') + '</p>'
      + '<div style="display:flex;gap:8px"><button class="ghost-btn" id="haoI_go" style="flex:1;border-color:var(--accent);color:var(--accent)">' + t('srcImport') + '</button>'
      + '<button class="ghost-btn" id="haoI_cancel" style="flex:1">' + t('srcCancel') + '</button></div>';
    var sheet = openSheet(html);
    sheet.querySelector('#haoI_cancel').addEventListener('click', closeSheet);
    sheet.querySelector('#haoI_file').addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0];
      if (!f) return;
      var done = function (res) {
        try {
          var out;
          if (/\.js$/i.test(f.name)) out = importLxScript(typeof res === 'string' ? res : String(res));
          else out = importSourceText(typeof res === 'string' ? res : String(res));
          closeSheet(); toast(t('srcImported') + '：' + (out.def && out.def.name ? out.def.name : 'backup')); renderSourcesPage(_container);
        } catch (err) { toast(err.message); }
      };
      if (/\.js$/i.test(f.name)) { var r1 = new FileReader(); r1.onload = function () { done(String(r1.result || '')); }; r1.readAsText(f); }
      else importSourceFile(f).then(function (out) { closeSheet(); toast(t('srcImported')); renderSourcesPage(_container); }).catch(function (err) { toast(err.message); });
    });
    sheet.querySelector('#haoI_go').addEventListener('click', function () {
      var text = sheet.querySelector('#haoI_text').value.trim();
      var url = sheet.querySelector('#haoI_url').value.trim();
      var run = text ? Promise.resolve().then(function () { var looksLx = /@name|inited|function\s+\w+\s*\(/.test(text); if (looksLx) { return importLxScript(text); } try { return importSourceText(text); } catch (e1) { return importLxScript(text); } })
        : url ? importSourceUrl(url) : Promise.reject(new Error(t('srcPasteJson')));
      run.then(function (out) { closeSheet(); toast(t('srcImported') + (out.def && out.def.name ? '：' + out.def.name : '')); renderSourcesPage(_container); })
        .catch(function (e) { toast(e.message); });
    });
  }
  function bindSourcesPage(el) {
    el.addEventListener('click', function (e) {
      var tabBtn = e.target.closest('[data-tab]');
      if (tabBtn) { _tab = tabBtn.getAttribute('data-tab'); renderSourcesPage(_container); return; }
      var actBtn = e.target.closest('[data-act]');
      if (!actBtn) return;
      var act = actBtn.getAttribute('data-act');
      if (act === 'add') { openSourceEditor(_tab === 'other' ? 'video' : _tab, null); return; }
      if (act === 'import') { openImportDialog(); return; }
      if (act === 'export') { downloadExport(); toast(t('srcExport')); return; }
      if (act === 'reset') { openImportDialog(); return; }
      if (act === 'saveOther') {
        var d = document.getElementById('haoDanmaku');
        if (d) setDanmakuEndpoint(d.value);
        toast(t('srcSaved')); return;
      }
      var card = actBtn.closest('.card');
      if (!card) return;
      var kind = card.getAttribute('data-kind');
      var id = card.getAttribute('data-id');
      if (act === 'toggle') {
        var cur = getList(kind).filter(function (x) { return String(x[KIND_ID_FIELD[kind]]) === String(id); })[0];
        if (cur) { setSourceEnabled(kind, id, !cur.enabled); renderSourcesPage(_container); }
      } else if (act === 'edit') openSourceEditor(kind, id);
      else if (act === 'del') {
        if (typeof root.confirm === 'function' && !root.confirm(t('srcConfirmDel'))) return;
        var r = deleteSource(kind, id);
        toast(r.ok ? t('srcDeleted') : (r.error || t('srcTestFail')));
        renderSourcesPage(_container);
      } else if (act === 'test') {
        var item2 = getList(kind).filter(function (x) { return String(x[KIND_ID_FIELD[kind]]) === String(id); })[0];
        if (!item2) return;
        actBtn.textContent = '…';
        testSource(kind, item2).then(function (res) {
          toast((res.ok ? t('srcTestOk') + ' · ' : t('srcTestFail') + ' · ') + (res.ok ? (res.info || '') : (res.error || '')) + '（' + res.ms + 'ms）');
          renderSourcesPage(_container);
        });
      }
    });
  }

  /* ---------- 对外接口 ---------- */
  return {
    version: 1,
    SOURCE_FORMAT: SOURCE_FORMAT,
    DEFAULT_VIDEO: DEFAULT_VIDEO, DEFAULT_MUSIC: DEFAULT_MUSIC, DEFAULT_LIVE: DEFAULT_LIVE,
    getVideoSources: getVideoSources, getMusicResolvers: getMusicResolvers, getLivePlatforms: getLivePlatforms,
    getDanmakuEndpoint: getDanmakuEndpoint, setDanmakuEndpoint: setDanmakuEndpoint,
    addSource: addSource, updateSource: updateSource, deleteSource: deleteSource, setSourceEnabled: setSourceEnabled,
    testSource: testSource, resolveWithTemplate: resolveWithTemplate,
    parseSourceText: parseSourceText, importSourceText: importSourceText,
    importSourceUrl: importSourceUrl, importSourceFile: importSourceFile,
    parseLxSourceScript: parseLxSourceScript, importLxScript: importLxScript,
    exportAll: exportAll, importBackup: importBackup, downloadExport: downloadExport,
    resetAll: resetAll, resetKind: resetKind,
    renderSourcesPage: renderSourcesPage, openSourceEditor: openSourceEditor, openImportDialog: openImportDialog,
    I18N: I18N, t: t,
    // 供测试注入
    _internals: { lsGet: lsGet, lsSet: lsSet, lsDel: lsDel, haoFetch: haoFetch, TEST_SONG: TEST_SONG }
  };
});
