// HAo Studio 独立版 — 音乐解析器模块 (c) 线
// 移植自网站服务器 ~/workspace/deploy/chen-hao-shop/server.js 的
// /api/music/play-url BUILTIN 实现（只读参考，未改服务器），
// 加上 web/app.js 已有的 DIRECT_RESOLVERS 4 个与 Huibq 模板源，共 14 个。
//
// 依赖注入：本模块只依赖一个注入的 fetchJson(url, opts, timeout) 函数
// （返回解析后的 JSON，HTTP 非 2xx / 解析失败时 throw）。
//   - App 内：调用方传入 nativeJson（Swift nativeFetch 桥，无 CORS 限制）。
//   - 浏览器测试：传入基于 window.fetch 的封装（仅 CORS-open 的源能用）。
//   - Node 测试：传入基于 global fetch 的封装。
// Huibq key 刷新用 fetchText（jsdelivr，CORS *，file:// 也能用）同样可注入。
// 未注入时：fetchJson 优先用 window.nativeJson，否则用全局 fetch；
// fetchText 用全局 fetch。
//
// outer 解析器已放弃：它需读 302 redirect 的 Location 头，
// nativeFetchReply 不回头——见 PLAYER_SPEC.md。
(function (global) {
  'use strict';

  var MUSIC_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
  var HUIBQ_API = 'https://lxmusicapi.onrender.com';
  var HUIBQ_KEY_URL = 'https://cdn.jsdelivr.net/gh/tfappstore/lx-music-source@main/huibq/latest.js';
  var HUIBQ_SEED_KEY = 'share-v3';
  var XH_TOKEN_URL = 'https://yy1.zddyr.top/lx/api/token.php';

  var QUALITY_CHAIN = ['hires', 'lossless', '320k', '128k'];
  var QRANK = { hires: 4, lossless: 3, '320k': 2, '128k': 1 };

  // ---- 可注入的 transport（默认实现） ----
  var _fetchJson = null;   // (url, opts, timeoutMs) => Promise<json>
  var _fetchText = null;   // (url, opts, timeoutMs) => Promise<string>
  var _timeoutMs = 5000;   // 单个解析器超时（服务器同款 5s）

  function defaultFetchJson(url, opts, ms) {
    if (global.nativeJson) return global.nativeJson(url, opts, ms || 10000);
    if (typeof fetch === 'function') {
      return fetch(url, Object.assign({}, opts || {}, { signal: AbortSignal.timeout(ms || 10000) }))
        .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); });
    }
    return Promise.reject(new Error('no fetchJson available'));
  }
  function defaultFetchText(url, opts, ms) {
    if (typeof fetch === 'function') {
      return fetch(url, Object.assign({}, opts || {}, { signal: AbortSignal.timeout(ms || 10000) }))
        .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.text(); });
    }
    return Promise.reject(new Error('no fetchText available'));
  }
  function fetchJson(url, opts, ms) { return (_fetchJson || defaultFetchJson)(url, opts, ms); }
  function fetchText(url, opts, ms) { return (_fetchText || defaultFetchText)(url, opts, ms); }

  // ---- 小工具 ----
  function toHttps(u) {
    if (!u || typeof u !== 'string') return '';
    return u.indexOf('http://') === 0 ? 'https://' + u.slice(7) : u;
  }
  function enc(s) { return encodeURIComponent(String(s == null ? '' : s)); }
  function withTimeout(p, ms) {
    return Promise.race([p, new Promise(function (res) { setTimeout(function () { res(''); }, ms); })]);
  }
  function lsGet(k) { try { return (global.localStorage && global.localStorage.getItem(k)) || ''; } catch (e) { return ''; } }
  function lsSet(k, v) { try { if (global.localStorage) global.localStorage.setItem(k, v); } catch (e) {} }

  // ---- 音质映射（与服务器一致） ----
  // srcQuality：模板源用（hires/lossless -> flac）
  function srcQuality(q) { return (q === 'hires' || q === 'lossless') ? 'flac' : q; }
  // songLevel：yutang / kangqi / qjqq 用
  function songLevel(q) { return (q === 'hires' || q === 'lossless') ? 'lossless' : q === '320k' ? 'exhigh' : 'standard'; }
  // gdBr：gd 用
  function gdBr(q) { return (q === 'hires' || q === 'lossless') ? 999 : q === '320k' ? 320 : 128; }
  // kwBr：oiapi_kw 用
  function kwBr(q) { return (q === 'hires' || q === 'lossless') ? 1 : q === '320k' ? 2 : 3; }
  // lxQuality：zddyr / xinghai 用（hires 保持 hires，lossless -> flac）
  function lxQuality(q) { return q === 'hires' ? 'hires' : q === 'lossless' ? 'flac' : q; }
  // wwwwebQuality：kw 平台最高只到 320k，其余 hires/lossless -> flac
  function wwwwebQuality(q, pf) {
    if (pf === 'kw') return (q === 'hires' || q === 'lossless') ? '320k' : q;
    return (q === 'hires' || q === 'lossless') ? 'flac' : q;
  }
  // extraQuality：某解析器在某档返回的 URL 实际是什么音质（用于候选排序与徽章显示，
  // 与服务器 extraQuality() 一致；无明确映射的解析器按 320k 计）
  function extraQuality(key, q, pf) {
    if (key === 'gd' || key === 'yutang' || key === 'kangqi' || key === 'qjqq' || key === 'zddyr') return q;
    if (key === 'oiapi_kw') return q;
    if (key === 'xinghai') return pf === 'kw' ? '128k' : q;
    if (key === 'tang') return q;
    if (key === 'wwwweb') {
      if (q === 'hires') return 'lossless';
      if (pf === 'kw' && (q === 'hires' || q === 'lossless')) return '320k';
      return q;
    }
    if (key === 'zddyr_kw') return q;
    if (key === 'huibq') return (q === 'hires' || q === 'lossless') ? '320k' : q;
    return '320k'; // lzm / oiapi_wy / hyw：不声明音质，按 320k 计
  }

  // ---- 星海 token（服务器 getXhToken 移植：5 分钟 TTL，缓存 4 分钟） ----
  var _xhToken = '', _xhTokenAt = 0, _xhTokenPromise = null;
  function xhDeviceId() {
    var d = lsGet('hao_sa_xh_device');
    if (!d) {
      d = 'lx-sa-' + Math.random().toString(16).slice(2, 10) + Date.now().toString(36);
      lsSet('hao_sa_xh_device', d);
    }
    return d;
  }
  function getXhToken() {
    if (_xhToken && Date.now() - _xhTokenAt < 240000) return Promise.resolve(_xhToken);
    if (!_xhTokenPromise) {
      _xhTokenPromise = (function () {
        return fetchJson(XH_TOKEN_URL + '?device_id=' + enc(xhDeviceId()),
          { headers: { 'User-Agent': 'lx-music' } }, 6000)
          .then(function (j) {
            var tk = (j && j.data && j.data.token) || '';
            if (tk) { _xhToken = tk; _xhTokenAt = Date.now(); }
            return tk;
          })
          .catch(function () { return ''; });
      })().finally(function () { _xhTokenPromise = null; });
    }
    return _xhTokenPromise;
  }

  // ---- Huibq key（jsdelivr 取最新，缓存 1h；失败用种子 key） ----
  var _huibqKey = lsGet('hao_sa_huibq_key') || '', _huibqKeyAt = 0;
  (function () { var at = parseInt(lsGet('hao_sa_huibq_key_at') || '0', 10); if (at) _huibqKeyAt = at; })();
  function getHuibqKey() {
    if (_huibqKey && Date.now() - _huibqKeyAt < 3600000) return Promise.resolve(_huibqKey);
    return refreshHuibqKey().then(function () { return _huibqKey || HUIBQ_SEED_KEY; });
  }
  function refreshHuibqKey() {
    return fetchText(HUIBQ_KEY_URL, null, 10000).then(function (code) {
      var m = (code || '').match(/API_KEY\s*=\s*['"]([^'"]+)['"]/);
      if (m && m[1]) {
        _huibqKey = m[1]; _huibqKeyAt = Date.now();
        lsSet('hao_sa_huibq_key', _huibqKey);
        lsSet('hao_sa_huibq_key_at', String(_huibqKeyAt));
        return true;
      }
      return false;
    }).catch(function () { return false; });
  }
  // Huibq 模板源：key 过期（code===1）时刷新一次再试（服务器 tryTemplate 同款）
  function huibqUrl(songId, pf, q) {
    function once() {
      return getHuibqKey().then(function (key) {
        return fetchJson(HUIBQ_API + '/url/' + pf + '/' + enc(songId) + '/' + srcQuality(q),
          { headers: { 'X-Request-Key': key, 'User-Agent': 'lx-music-request/1.0' } }, 8000)
          .then(function (j) { return { j: j, key: key }; });
      });
    }
    return once().then(function (r) {
      var j = r.j;
      if (j && j.code === 1) {
        return refreshHuibqKey().then(function (ok) {
          if (!ok) return '';
          return once().then(function (r2) {
            var j2 = r2.j;
            return (j2 && (j2.url || (j2.data && j2.data.url))) ? toHttps(j2.url || j2.data.url) : '';
          });
        });
      }
      return (j && (j.url || (j.data && j.data.url))) ? toHttps(j.url || j.data.url) : '';
    }).catch(function () { return ''; });
  }

  // ---- 14 个解析器（顺序 = 服务器 sort_order；Huibq 模板源排第一） ----
  // fn(ctx, q) -> Promise<url|string>，失败/无结果返回 ''，永不 throw。
  // ctx = { songId, platform, title }。
  // platforms 栏 = 服务器 music_sources.platforms（sourceApplies 同款过滤）。
  var RESOLVERS = [
    {
      key: 'huibq', name: 'Huibq', platforms: ['wy', 'tx', 'kg', 'kw', 'mg'], enabled: true, order: 1,
      note: 'LX Music 模板源，key 经 jsdelivr 自动刷新；hires/lossless 只到 320k（模板声明 kw/kg/tx/wy/mg 均 128k/320k）。',
      fn: function (ctx, q) { return huibqUrl(ctx.songId, ctx.platform, q); }
    },
    {
      key: 'tang', name: 'tang', platforms: ['tx'], enabled: true, order: 15,
      note: 'QQ FLAC：按档取不同字段（pq/sq/hq/standard）；songId 为 QQ songmid。',
      fn: function (ctx, q) {
        return fetchJson('https://tang.api.s01s.cn/music_open_api.php?mid=' + enc(ctx.songId),
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs).then(function (j) {
            if (!j || !j.song_play_url) return '';
            if (q === 'hires') return toHttps(j.song_play_url_pq || '');
            if (q === 'lossless') return toHttps(j.song_play_url_sq || '');
            if (q === '320k') return toHttps(j.song_play_url_hq || '');
            return toHttps(j.song_play_url_standard || j.song_play_url || '');
          }).catch(function () { return ''; });
      }
    },
    {
      key: 'lzm', name: 'lzm', platforms: ['wy'], enabled: true, order: 20,
      note: 'POST，无音质参数；返回 j.data 即 URL。',
      fn: function (ctx, q) {
        return fetchJson('https://music.lzmhhh.com/api/music/url',
          { method: 'POST', headers: { 'User-Agent': MUSIC_UA, 'Content-Type': 'application/x-www-form-urlencoded', 'Referer': 'https://music.lzmhhh.com/' }, body: 'id=' + enc(ctx.songId) + '&type=wy' }, _timeoutMs)
          .then(function (j) { return (j && j.data) ? toHttps(j.data) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'zddyr', name: 'zddyr', platforms: ['wy'], enabled: true, order: 25,
      note: 'LX API（yy.zddyr.top），wy 专用；hires 保持 hires，lossless -> flac。',
      fn: function (ctx, q) {
        return fetchJson('https://yy.zddyr.top/lx/api/?source=wy&songmid=' + enc(ctx.songId) + '&quality=' + lxQuality(q),
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { return (j && j.code === 200 && j.url) ? toHttps(j.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'gd', name: 'GD Studio', platforms: ['wy'], enabled: true, order: 30,
      note: 'br 参数：hires/lossless=999，320k=320，128k=128。',
      fn: function (ctx, q) {
        return fetchJson('https://music-api.gdstudio.xyz/api.php?types=url&id=' + enc(ctx.songId) + '&source=netease&br=' + gdBr(q),
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { return (j && j.url) ? toHttps(j.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'xinghai', name: '星海', platforms: ['wy', 'kg', 'kw'], enabled: true, order: 40,
      note: '需 X-Token（yy1.zddyr.top/lx/api/token.php，4 分钟缓存）；kg 需 mainHash=songId；tx 映射为 qq（本模块按服务器 platforms 只开 wy/kg/kw）。',
      fn: function (ctx, q) {
        return getXhToken().then(function (tk) {
          if (!tk) return '';
          var bs = ({ wy: 'wy', tx: 'qq', kg: 'kg', kw: 'kw' })[ctx.platform] || ctx.platform;
          var url = 'https://yy1.zddyr.top/lx/api/?source=' + bs + '&songmid=' + enc(ctx.songId) + '&quality=' + lxQuality(q);
          if (ctx.platform === 'kg') url += '&mainHash=' + enc(ctx.songId);
          return fetchJson(url,
            { headers: { 'User-Agent': 'lx-music', 'X-Client': 'XingHaiMusicSource/v3.2.19 (Linux)', 'X-Token': tk } }, _timeoutMs)
            .then(function (j) { return (j && j.code === 200 && j.url) ? toHttps(j.url) : ''; });
        }).catch(function () { return ''; });
      }
    },
    {
      key: 'oiapi_wy', name: 'oiapi-网易', platforms: ['wy'], enabled: true, order: 60,
      note: '无音质参数；取 j.data[0].url（code===0）。',
      fn: function (ctx, q) {
        return fetchJson('https://oiapi.net/api/Music_163?id=' + enc(ctx.songId),
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { return (j && j.code === 0 && Array.isArray(j.data) && j.data[0] && j.data[0].url) ? toHttps(j.data[0].url) : ''; })
          .catch(function () { return ''; });
      }
    },
    {
      key: 'qjqq', name: 'qjqq', platforms: ['wy'], enabled: true, order: 70,
      note: 'POST Song_V1，level 映射同 kangqi；取 j.data.url。',
      fn: function (ctx, q) {
        return fetchJson('https://metings.qjqq.cn/Song_V1',
          { method: 'POST', headers: { 'User-Agent': MUSIC_UA, 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'url=' + enc(ctx.songId) + '&level=' + songLevel(q) + '&type=json' }, _timeoutMs)
          .then(function (j) { return (j && j.data && j.data.url) ? toHttps(j.data.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'kangqi', name: 'kangqi', platforms: ['wy'], enabled: true, order: 80,
      note: 'POST Song_V1，level 映射同 qjqq；取 j.data.url。',
      fn: function (ctx, q) {
        return fetchJson('https://ncm.kangqiovo.com/Song_V1',
          { method: 'POST', headers: { 'User-Agent': MUSIC_UA, 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'url=' + enc(ctx.songId) + '&level=' + songLevel(q) + '&type=json' }, _timeoutMs)
          .then(function (j) { return (j && j.data && j.data.url) ? toHttps(j.data.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'yutang', name: 'yutang', platforms: ['wy'], enabled: true, order: 90,
      note: 'GET Song_V1，level 映射同 kangqi；取 j.url 或 j.data.url。',
      fn: function (ctx, q) {
        return fetchJson('https://api.yutangxiaowu.cn/api/music/Song_V1?url=' + enc(ctx.songId) + '&level=' + songLevel(q) + '&type=json',
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { if (j && j.url) return toHttps(j.url); if (j && j.data && j.data.url) return toHttps(j.data.url); return ''; })
          .catch(function () { return ''; });
      }
    },
    {
      key: 'oiapi_kw', name: 'oiapi-酷我', platforms: ['kw'], enabled: true, order: 100,
      note: '按歌名搜索（需 title）；br 参数：hires/lossless=1，320k=2，128k=3。',
      fn: function (ctx, q) {
        if (!ctx.title) return Promise.resolve('');
        return fetchJson('https://oiapi.net/api/Kuwo?msg=' + enc(ctx.title) + '&n=1&br=' + kwBr(q),
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { return (j && j.data && j.data.url) ? toHttps(j.data.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'hyw', name: 'HYWmusic', platforms: ['wy'], enabled: false, order: 110,
      note: '默认关闭（服务器 enabled=0 同款）。直连 IP 103.79.184.97，quality 写死 320k；用共享 X-Card-Key。',
      fn: function (ctx, q) {
        return fetchJson('https://103.79.184.97/api/music/url?platform=wy&source=wy&songId=' + enc(ctx.songId) + '&quality=320k',
          { headers: { 'User-Agent': MUSIC_UA, 'X-Card-Key': '6C1F-53W0-GRKI-EVFG' } }, _timeoutMs)
          .then(function (j) { return (j && j.code === 200 && j.url) ? toHttps(j.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'wwwweb', name: 'wwwweb', platforms: ['wy', 'kw'], enabled: true, order: 120,
      note: 'POST JSON（source/musicId/quality）；kw 最高 320k；UA lx-music-desktop/2.10.1。',
      fn: function (ctx, q) {
        return fetchJson('https://c.wwwweb.top/music/url',
          { method: 'POST', headers: { 'User-Agent': 'lx-music-desktop/2.10.1', 'Content-Type': 'application/json', 'X-Api-Key': '' }, body: JSON.stringify({ source: ctx.platform, musicId: ctx.songId, quality: wwwwebQuality(q, ctx.platform) }) }, _timeoutMs)
          .then(function (j) { return (j && j.code === 200 && j.url) ? toHttps(j.url) : ''; }).catch(function () { return ''; });
      }
    },
    {
      key: 'zddyr_kw', name: '星海酷我', platforms: ['kw'], enabled: true, order: 130,
      note: '按歌名搜索（需 title）；hires/lossless 直接拒绝（返回空，走降级链）。',
      fn: function (ctx, q) {
        if (!ctx.title) return Promise.resolve('');
        if (q === 'hires' || q === 'lossless') return Promise.resolve('');
        return fetchJson('https://yy.zddyr.top/lx/api/?source=kw&name=' + enc(ctx.title) + '&singer=&songmid=' + enc(ctx.songId) + '&interval=&albumName=&quality=' + q,
          { headers: { 'User-Agent': MUSIC_UA } }, _timeoutMs)
          .then(function (j) { return (j && j.code === 200 && j.url) ? toHttps(j.url) : ''; }).catch(function () { return ''; });
      }
    }
  ];

  // ---- 启用状态（读 HaoSources；无则用内置默认） ----
  // HaoSources.getMusicResolvers() -> [{key, name, platforms, enabled, fn}]
  // 返回后以 HaoSources 的 enabled 为准；内置 fn 永远保留（HaoSources 只管开关）。
  function enabledMap() {
    var map = null;
    try {
      var hs = global.HaoSources;
      if (hs && typeof hs.getMusicResolvers === 'function') {
        var list = hs.getMusicResolvers() || [];
        map = {};
        list.forEach(function (r) { if (r && r.key) map[r.key] = r.enabled !== false; });
      }
    } catch (e) {}
    return map;
  }
  function applicableResolvers(pf) {
    var map = enabledMap();
    return RESOLVERS.filter(function (r) {
      var en = map ? (map[r.key] !== undefined ? map[r.key] : r.enabled) : r.enabled;
      return en && r.platforms.indexOf(pf) !== -1;
    }).sort(function (a, b) { return a.order - b.order; });
  }

  // ---- 单档收集（服务器 collectAt 同款逻辑） ----
  // 并行试全部适用解析器；非 hi 档：首个 URL 后 350ms 收尾；
  // hi 档（hires/lossless）：等到拿到无损/hires 候选才 350ms 收尾，否则等满 2.5s，
  // 避免 Huibq 的 320k 先到、慢的无损解析器永远进不了候选；硬上限 5s。
  function collectAt(q, ctx) {
    var hi = q === 'hires' || q === 'lossless';
    var jobs = applicableResolvers(ctx.platform);
    if (!jobs.length) return Promise.resolve([]);
    return new Promise(function (resolve) {
      var out = new Array(jobs.length).fill(null);
      var done = 0, finished = false;
      var finish = function () { if (!finished) { finished = true; resolve(out.filter(Boolean)); } };
      var hiCap = hi ? Math.min(2500, _timeoutMs / 2) : _timeoutMs;
      jobs.forEach(function (job, idx) {
        withTimeout(job.fn(ctx, q), _timeoutMs).then(function (u) {
          out[idx] = { key: job.key, name: job.name, url: u || '' };
          if (!u) return;
          var ql = extraQuality(job.key, q, ctx.platform);
          var early = hi ? (ql === 'lossless' || ql === 'hires') : out.filter(function (r) { return r && r.url; }).length === 1;
          if (early) setTimeout(finish, 350);
        }).catch(function () {
          out[idx] = { key: job.key, name: job.name, url: '' };
        }).finally(function () { done++; if (done === jobs.length) finish(); });
      });
      setTimeout(finish, hiCap);
    }).then(function (results) {
      var cands = [];
      results.forEach(function (r) {
        if (!r.url || cands.length >= 3) return;
        var u = toHttps(r.url);
        if (!u || cands.some(function (c) { return c.url === u; })) return;
        cands.push({ url: u, via: r.name, q: extraQuality(r.key, q, ctx.platform) });
      });
      cands.sort(function (a, b) { return (QRANK[b.q] || 0) - (QRANK[a.q] || 0); });
      return cands;
    });
  }

  // ---- 主入口 ----
  // resolvePlayUrl(songId, platform, quality, title)
  //   -> Promise<{ url, candidates, quality, via } | null>
  // 逐档降级：hires -> lossless -> 320k -> 128k（从请求的档开始）；
  // 每档并行试全部启用解析器；首档有候选即返回（按音质排序，最高在前）。
  // 下一首恢复最高音质是调用方的责任：每次都传用户选定的最高档（curQuality），
  // 本模块不持久化降级结果（站内 fi 规则）。
  function resolvePlayUrl(songId, platform, quality, title) {
    if (!songId) return Promise.resolve(null);
    var pf = ['wy', 'tx', 'kg', 'kw', 'mg'].indexOf(platform) !== -1 ? platform : 'wy';
    var q0 = QUALITY_CHAIN.indexOf(quality) >= 0 ? quality : '320k';
    var ctx = { songId: String(songId), platform: pf, title: title || '' };
    var chain = QUALITY_CHAIN.slice(QUALITY_CHAIN.indexOf(q0));
    var i = 0;
    function next() {
      if (i >= chain.length) return Promise.resolve(null);
      var q = chain[i++];
      return collectAt(q, ctx).then(function (cands) {
        if (cands.length) {
          return { url: cands[0].url, candidates: cands.map(function (c) { return c.url; }), quality: cands[0].q, via: cands[0].via };
        }
        return next();
      });
    }
    return next();
  }

  // ---- 清单 ----
  function listResolvers() {
    var map = enabledMap();
    return RESOLVERS.map(function (r) {
      var en = map ? (map[r.key] !== undefined ? map[r.key] : r.enabled) : r.enabled;
      return { key: r.key, name: r.name, platforms: r.platforms.slice(), enabled: en, order: r.order, note: r.note || '' };
    }).sort(function (a, b) { return a.order - b.order; });
  }

  // ---- 注入配置（测试 / 调用方） ----
  function configure(opts) {
    opts = opts || {};
    if (typeof opts.fetchJson === 'function') _fetchJson = opts.fetchJson;
    if (typeof opts.fetchText === 'function') _fetchText = opts.fetchText;
    if (typeof opts.timeoutMs === 'number' && opts.timeoutMs > 0) _timeoutMs = opts.timeoutMs;
  }

  var api = {
    resolvePlayUrl: resolvePlayUrl,
    refreshHuibqKey: refreshHuibqKey,
    getHuibqKey: getHuibqKey,
    getXhToken: getXhToken,
    listResolvers: listResolvers,
    configure: configure,
    QUALITY_CHAIN: QUALITY_CHAIN,
    // 仅供测试：音质映射与内部常量
    _test: {
      srcQuality: srcQuality, songLevel: songLevel, gdBr: gdBr, kwBr: kwBr,
      lxQuality: lxQuality, wwwwebQuality: wwwwebQuality, extraQuality: extraQuality,
      toHttps: toHttps, resolvers: RESOLVERS
    }
  };

  global.HaoResolvers = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
