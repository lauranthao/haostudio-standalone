// Apple CMS video sources — 19 defaults.
//
// Port of sources.js `DEFAULT_VIDEO` (which itself reuses the web
// app.js `DIRECT_VIDEO_SEEDS`, same real ids). `sort` ascending =
// priority, measured 2026-11-17 from the VM (relative only — VM goes
// through an egress proxy; chen's phone is the final judge):
//   非凡 0.43–1.28s, 金鹰 0.33–1.00s, 非凡主站 0.83s, 极速 1.09s,
//   魔都 1.28s, iKun 1.19s, 光速 1.20s, 虎牙 1.22s, 新狼 1.20s,
//   厂长 1.32s, 豪华 1.42s, 红牛 1.44s, 速播备用 1.50s,
//   速播 1.62–1.73s, 如意 2.40s (SLOW, demoted), 360 2.32–2.59s
//   (SLOW, demoted), 量子 2.34–3.18s (SLOWEST, shipped OFF),
//   暴风 1.52–2.51s (search only).
// Candidates tested and REJECTED: 天空/八戒/卧龙/旺旺/最大/OK/诺讯/
// 快车 (dead or redirect), 樱花 2.19s, 闪电 6.75s, U酷 2.98s,
// 索尼 1.91s, 茅台 3.72s, 天涯 1.77s, 星夜 2.95s, 看看 1.91s,
// 1080 (Cloudflare challenge). Only 非凡主站 was fast enough to add.
// 量子 is shipped OFF (kind still play, enabled=false); 非凡 is
// kind=search (search only, play URLs not trusted).
//
// Bump [kVideoSourcesRevision] whenever this list changes (new source
// / re-prioritised sorts): VideoSourcesStore merges missing defaults
// into the persisted list once per revision.
//
// Sources are user-editable (settings → source management) and
// persisted in Hive `hao_sa_video`; [VideoSourcesStore] (in
// video_history_store.dart's companion file below) returns enabled
// sources sorted by `sort`, with the "at least one video source must
// remain" delete guard. Source ids drift daily — never hardcode video
// ids, and never assume a source id survives a reseed.

import 'video_models.dart';

/// Defaults revision for the merge in VideoSourcesStore.getAll().
/// 1 = the original 17 sources; 2 = +非凡主站, speed re-prioritised;
/// 3 = 金鹰/非凡/非凡主站 apiUrl http→https (verified 2026-11-19:
/// all three hosts answer real CMS requests over https — see the
/// header note on the three sources). The merge upgrades a stored
/// http twin to its https twin in place (same id, sort and enabled —
/// a user's reorder / toggle is never touched by the upgrade).
/// 4 = +电影天堂资源 (dyttzy, verified 2026-11-22: ?ac=videolist
/// returns 200, code 1, total 85263, play URLs present).
/// 5 = −暴风资源 (deleted 2026-11-23: API answers but play files
/// 404 on two titles / two CDN hosts — found but never plays).
const int kVideoSourcesRevision = 5;

/// UA for CMS video + Douban search-page fallback (must be verbatim —
/// several upstreams key behaviour off it).
const String kDirectVideoUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

/// UA for music + Douban abstract/mobile calls (Douban headers).
const String kDirectMusicUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
    'Mobile/15E148 Safari/604.1';

/// The 19 default CMS sources, in shipped order (already sort order).
const List<VideoSource> kDefaultVideoSources = [
  VideoSource(
    id: 12,
    name: '金鹰资源',
    // https verified 2026-11-19 (was http): `?ac=list` over https
    // returns 200 + the same CMS JSON as http (code 1, total 118675).
    apiUrl: 'https://jyzyapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 5,
  ),
  VideoSource(
    id: 13,
    name: '非凡资源',
    // https verified 2026-11-19 (was http): `?ac=list` and a real
    // `?ac=videolist&wd=` search both return 200 over https.
    apiUrl: 'https://ffzy5.tv/api.php/provide/vod',
    kind: 'search',
    enabled: true,
    sort: 6,
  ),
  VideoSource(
    id: 18,
    name: '非凡主站',
    // https verified 2026-11-19 (was http): same as 非凡资源 — list
    // and search both 200 over https.
    apiUrl: 'https://cj.ffzyapi.com/api.php/provide/vod',
    kind: 'search',
    enabled: true,
    sort: 7,
  ),
  VideoSource(
    id: 8,
    name: '极速资源',
    apiUrl: 'https://jszyapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 10,
  ),
  VideoSource(
    id: 6,
    name: '魔都资源',
    apiUrl: 'https://caiji.moduapi.cc/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 11,
  ),
  VideoSource(
    id: 17,
    name: 'iKun资源',
    apiUrl: 'https://ikunzyapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 12,
  ),
  VideoSource(
    id: 7,
    name: '光速资源',
    apiUrl: 'https://api.guangsuapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 13,
  ),
  VideoSource(
    id: 9,
    name: '虎牙资源',
    apiUrl: 'https://www.huyaapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 14,
  ),
  VideoSource(
    id: 10,
    name: '新狼资源',
    apiUrl: 'https://api.xinlangapi.com/xinlangapi.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 15,
  ),
  VideoSource(
    id: 14,
    name: '厂长资源',
    apiUrl: 'https://api.changzhang.tv/api.php/provide/vod/',
    kind: 'play',
    enabled: true,
    sort: 16,
  ),
  VideoSource(
    id: 2,
    name: '豪华资源',
    apiUrl: 'https://hhzyapi.com/api.php/provide/vod/',
    kind: 'play',
    enabled: true,
    sort: 17,
  ),
  VideoSource(
    id: 1,
    name: '红牛资源',
    apiUrl: 'https://www.hongniuzy2.com/api.php/provide/vod/',
    kind: 'play',
    enabled: true,
    sort: 18,
  ),
  VideoSource(
    id: 15,
    name: '速播备用',
    apiUrl: 'https://subocaiji.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 19,
  ),
  VideoSource(
    id: 3,
    name: '速播资源',
    apiUrl: 'https://www.subozy.com/api.php/provide/vod/',
    kind: 'play',
    enabled: true,
    sort: 20,
  ),
  VideoSource(
    id: 16,
    name: '如意资源',
    apiUrl: 'https://cj.rycjapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 21,
  ),
  VideoSource(
    id: 11,
    name: '360资源',
    apiUrl: 'https://360zy.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 22,
  ),
  VideoSource(
    id: 4,
    name: '量子资源',
    apiUrl: 'https://cj.lziapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: false,
    sort: 23,
  ),
  // 2026-11-22: added per chen (tvbox-desktop CMS list); verified live:
  // ?ac=videolist returns 200, code 1, total 85263, play URLs present.
  // Measured 2.26s, so placed last per the file's speed convention.
  VideoSource(
    id: 19,
    name: '电影天堂资源',
    apiUrl: 'https://caiji.dyttzyapi.com/api.php/provide/vod',
    kind: 'play',
    enabled: true,
    sort: 25,
  ),
];

// NOTE 2026-11-23: 暴风资源 (id 5, bfzyapi.com) DELETED — its API
// still answers search/detail (code 1), but its play files are gone:
// the m3u8 for two different titles on two different CDN hosts
// (s3.bfllvip.com, s2.bfllvip.com) both returned 404, so titles
// from this source can be found but never play. 17 enabled sources
// remain; no replacement needed.

/// Enabled defaults, sorted by `sort` (the `getVideoSources()` shape).
List<VideoSource> defaultEnabledVideoSources() {
  final list = kDefaultVideoSources.where((s) => s.enabled).toList();
  list.sort((a, b) => a.sort.compareTo(b.sort));
  return list;
}

/// Adult type/title words — skipped in type map, home, daily, search.
const List<String> kDirectAdultWords = [
  '伦理',
  '福利',
  '成人',
  '情色',
  '三级',
  '写真',
  '美女',
  '激情',
  '性感',
];

bool isAdultVideo(String? type, String? name) {
  final t = type ?? '';
  final n = name ?? '';
  if (n.contains('里番') || t.contains('里番')) return true;
  return kDirectAdultWords.any((w) => t.contains(w) || n.contains(w));
}

/// Home type ordering (first 12 fetched, rows sorted by count, top 10).
const List<String> kVideoTypePriority = [
  '连续剧',
  '电视剧',
  '电影',
  '综艺',
  '动漫',
  '纪录片',
  '动作片',
  '喜剧片',
  '爱情片',
  '科幻片',
  '恐怖片',
  '剧情片',
  '战争片',
  '国产剧',
  '韩剧',
  '欧美剧',
  '日剧',
  '动漫电影',
  '国产动漫',
  '日本动漫',
  '中国动漫',
  '短剧',
  '港剧',
  '台剧',
  '泰剧',
  '港澳剧',
  '台湾剧',
  '古装片',
  '历史片',
  '惊悚片',
  '家庭片',
  '犯罪片',
  '冒险片',
  '动画片',
];

/// English subtitle for collection cards.
const Map<String, String> kVideoEnSub = {
  '电影': 'MOVIES',
  '连续剧': 'TV SHOWS',
  '电视剧': 'TV SHOWS',
  '综艺': 'VARIETY',
  '动漫': 'ANIMATION',
  '纪录片': 'DOCUMENTARY',
  '动漫电影': 'ANIMATED MOVIES',
  '短剧': 'SHORT DRAMA',
  '国产剧': 'CHINESE DRAMA',
  '韩剧': 'K-DRAMA',
  '欧美剧': 'WESTERN DRAMA',
  '日剧': 'J-DRAMA',
  '港剧': 'HK DRAMA',
  '台剧': 'TW DRAMA',
  '泰剧': 'THAI DRAMA',
};

/// Movie-vs-show split for home totals (totals are computed but NOT
/// rendered on home — Infuse H7 deletes the totals strip).
final RegExp kVideoMovieRe = RegExp(
  r'电影|纪录|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|古装片|历史片|惊悚片|家庭片|犯罪片|冒险片|动画片|伦理片',
);

/// Area aliases for by-type client-side filtering.
const Map<String, List<String>> kVideoAreaAlias = {
  '大陆': ['大陆', '中国大陆', '内地'],
  '香港': ['香港'],
  '台湾': ['台湾'],
  '美国': ['美国'],
  '韩国': ['韩国'],
  '日本': ['日本'],
  '英国': ['英国'],
};

const List<String> kKnownVideoAreas = [
  '大陆',
  '中国大陆',
  '内地',
  '香港',
  '台湾',
  '美国',
  '韩国',
  '日本',
  '英国',
];

/// Force http:// → https:// (all upstream URLs must be https).
String toHttps(String url) =>
    url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

/// True when a user-typed source URL would send API requests in the
/// clear (plain http://). Used by the source settings page to warn
/// before adding — never to block: the user's own sources are their
/// call.
bool isPlainHttpVideoSourceUrl(String url) =>
    url.trim().toLowerCase().startsWith('http://');
