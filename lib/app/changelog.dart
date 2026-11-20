// In-app update log data (chen 2026-11-20, Beans screenshot).
//
// Bundled in the app so the 更新日志 page works offline. Entries are
// sourced from the version.json release history of the flutter repo
// (release commits 943f107 / c6ad943 / 66d10c3 / b613a4e / caa3c2e /
// 4a749e2 — the zh changelog of each build), split into 新增功能 /
// 问题修复 bullets without adding anything the sources don't say:
// - 1.1.5 merges builds 18-22; build 21's partial pill fix is
//   superseded by build 22's thorough one, so only the latter is
//   listed; the one-time wallpaper note from build 19 is dropped.
// - 1.1.3's "已知" caveats (needs-phone-confirmation notes) are not
//   changelog items and are dropped.
// - Only versions sourced this way are listed; older versions are
//   left out rather than guessed.
// - Chinese only: the app has no flutter_localizations / i18n
//   (labels are hardcoded Chinese everywhere else too).

class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.title,
    this.features = const [],
    this.fixes = const [],
  });

  /// Display version, e.g. 'v1.1.5'.
  final String version;

  /// One-line summary of the release.
  final String title;

  /// 新增功能 items.
  final List<String> features;

  /// 问题修复 items.
  final List<String> fixes;
}

/// Newest first.
const List<ChangelogEntry> kChangelog = [
  ChangelogEntry(
    version: 'v1.1.5',
    title: '底栏透镜、自定义强调色与歌单导入',
    features: [
      '点 mini 播放器像网易那样放大成全屏播放器，右滑关闭回到 mini',
      '底栏胶囊改成液体玻璃透镜，滑动时拉长，颜色跟着胶囊走',
      '底栏胶囊动画按网易录屏重做：图标和文字经过透镜时放大扭曲，进透镜变红、出来变回原来的颜色',
      '设置里新增“自定义强调色”，色板可选，默认红，还能用滴管取屏幕上的颜色',
      '自定义强调色成为全 app 的强调色，开关、按钮、选中态都跟着变，设置里能恢复默认',
      '歌单导入支持网易短链接、手机端链接和整段分享文字粘贴，也支持酷狗、QQ、酷我歌单链接',
      '歌单广场、排行榜、听歌报告、每日推荐四张卡，底图改成第一首歌的封面，没有图时用渐变',
      '顶栏、mini 播放器、底栏和页面底色融为一体，整页连在一起',
    ],
    fixes: [
      '底栏胶囊重影彻底修了：图标层按胶囊形状裁开，透镜下面永远只有一份，静止、滑动、落定都不会再双份',
      '透镜不再用 Opacity 淡入淡出，滑动全程体不透明；静止的胶囊是实色椭圆，亮色深色都看得清',
      '滑动不再卡顿，四个页面切换时不再重建',
      '点心动模式再切歌不会再打开多个播放器页',
      '亮度/音量只留在视频和直播播放器里，退出播放器或切到后台就把亮度还给系统',
      '首页最近播放播歌/切歌后实时更新，不用切页面、不用重进',
      '底栏的玻璃回来了，胶囊顶边有亮线，后面滚动的内容会雾化',
      '打开榜单详情后排行榜封面会刷新，不会一直用旧的',
    ],
  ),
  ChangelogEntry(
    version: 'v1.1.4',
    title: '私人漫游、心动模式与 Gitee 更新',
    features: [
      '新增私人漫游和心动模式，在我的歌单下面，用本地收藏和最近播放做种子，不用登录',
      '不喜欢的歌点 ⋯ 选“不喜欢”，以后不再推',
      'mini 播放器现在音乐区所有页面都有，打开全屏播放器和切到视频/直播时不显示',
      '在线更新改走 Gitee（国内），商店做备用；服务器 502 也会重试一次；总超时放宽到 30 秒',
    ],
    fixes: [
      '最近播放/我的歌单的收起状态现在记住了，切 tab、重启都不会再自己打开',
      '搜歌页切歌单/歌手/专辑会自动搜，切回去显示缓存，不重复搜',
    ],
  ),
  ChangelogEntry(
    version: 'v1.1.3',
    title: '系统音量、直播恢复与界面清理',
    features: [
      '视频和直播的音量现在改的是系统音量，上下滑动调音量，按音量键同步显示',
      '单线路直播卡住会自动重新拉流恢复',
      '点播播完自动下一集，换源后继续从原来的进度播',
      '歌单广场行尾加了播放数',
      'Douban 按标题+年份匹配影片，默认源全部改 https',
    ],
    fixes: [
      '历史记录按年份去重，播中换源不再强制跳对方线路 1',
      'ikun 音源停用（域名已失效，可手动重开），jiexiang 修复',
      '搜不到可播的歌时如实提示，不再谎称无源',
      '音乐首页、播放器、直播首页、直播间、设置、视频详情、搜歌删了标语和提示文案',
      '浅色下文字对比度提到 WCAG 4.5:1',
    ],
  ),
];
