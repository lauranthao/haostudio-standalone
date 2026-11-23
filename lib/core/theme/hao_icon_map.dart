// Material → Cupertino icon map (N-2, 1.1.6 原生感).
//
// iOS native feel needs Cupertino glyphs: ~300 `Icons.` uses, 0
// `CupertinoIcons` before this batch. Swapping all at once is L work,
// so batches record here what is swapped and what is still pending —
// the next batch extends the SWAPPED table instead of re-auditing.
//
// Swapped this batch (A 组, 2026-11-22):
// | Material                | Cupertino                          | Where                       |
// | Icons.movie             | CupertinoIcons.film                | 底栏 app_shell.dart:262     |
// | Icons.live_tv           | CupertinoIcons.tv                  | 底栏 app_shell.dart:263     |
// | Icons.music_note        | CupertinoIcons.music_note          | 底栏 app_shell.dart:264     |
// | Icons.settings          | CupertinoIcons.settings            | 底栏 app_shell.dart:265     |
// | Icons.arrow_back        | CupertinoIcons.back                | 影视详情 video_detail_page.dart:844，
// |                         |                                    | Emby 详情 emby_detail_page.dart:916 |
// | Icons.keyboard_arrow_down | CupertinoIcons.chevron_down      | 播放器 music_player_sheet.dart:578，
// |                         |                                    | 搜歌 song_search_page.dart:1608 |
// | Icons.tune              | CupertinoIcons.slider_horizontal_3 | 播放器 music_player_sheet.dart:583 |
// | Icons.more_horiz        | CupertinoIcons.ellipsis            | 播放器 music_player_sheet.dart:992 |
// | Icons.search            | CupertinoIcons.search              | 搜歌 song_search_page.dart:614  |
// | Icons.cancel            | CupertinoIcons.clear               | 搜歌 song_search_page.dart:658  |
// | Icons.chevron_right     | CupertinoIcons.chevron_right       | 搜歌 song_search_page.dart:1046,1117,1228 |
// | Icons.delete_outline    | CupertinoIcons.delete              | 搜歌 song_search_page.dart:1336 |
// | Icons.clear             | CupertinoIcons.clear               | 搜歌 song_search_page.dart:1416 |
//
// Pending (do NOT swap silently — each needs its own batch/owner):
// - 直播间悬浮返回键 live_room_page.dart:1889 (Icons.arrow_back):
//   文件属 B 组/直播组，A 组禁碰，等协调员定。
// - 播放器播放控制 (play/pause/skip)、收藏星、AirPlay、队列、
//   歌单/专辑/榜单的状态图标与品牌 logo：播放字形是 chen 定过的
//   播放器设计的一部分，只换主导航图标，控制字形留后批。
// - 其余约 280 处 `Icons.`：按页分批换，换一处核对一处 golden。

// Swapped in the audit-fix batch (2026-11-23, build 30):
// | Icons.swap_horiz      | CupertinoIcons.arrow_2_squarepath | 直播间导航栏 live_room_page.dart:2566 |
// | Icons.fullscreen      | CupertinoIcons.fullscreen         | 直播间导航栏 + 控制条 live_room_page  |
// | Icons.fullscreen_exit | CupertinoIcons.fullscreen_exit    | 直播间控制条 live_room_page.dart:1924 |
// | Icons.pause           | CupertinoIcons.pause              | 直播间控制条 live_room_page.dart:1827 |
// | Icons.play_arrow      | CupertinoIcons.play_arrow         | 直播间控制条 live_room_page.dart:1827 |
// | Icons.refresh         | CupertinoIcons.refresh            | 直播间控制条 live_room_page.dart:1837 |
// | Icons.chat_bubble_outline | CupertinoIcons.chat_bubble      | 直播间控制条 live_room_page.dart:1847 |
// | Icons.chat_bubble     | CupertinoIcons.chat_bubble_fill   | 直播间控制条 live_room_page.dart:1847 |
// | Icons.lock_open       | CupertinoIcons.lock_open          | 直播间控制条 live_room_page.dart:1912 |
// (Icons.settings was already mapped in A 组；直播间控制条复用同一映射。)
// Not swapped here: the drag HUD brightness/volume icons
// (live_room_page.dart:1794-1798) — transient gesture feedback, not
// controls — and the music player's three big white triangles, which
// are chen's custom design, never touched.
//
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Material → Cupertino replacements swapped so far (this batch).
/// Keyed by the old Material icon so the next batch can look a
/// replacement up instead of re-deciding it. (A `final`, not
/// `const`, map: `IconData` overrides `==`, so it cannot be a const
/// map key.)
final Map<IconData, IconData> haoCupertinoIconMap = {
  Icons.movie: CupertinoIcons.film,
  Icons.live_tv: CupertinoIcons.tv,
  Icons.music_note: CupertinoIcons.music_note,
  Icons.settings: CupertinoIcons.settings,
  Icons.arrow_back: CupertinoIcons.back,
  Icons.keyboard_arrow_down: CupertinoIcons.chevron_down,
  Icons.tune: CupertinoIcons.slider_horizontal_3,
  Icons.more_horiz: CupertinoIcons.ellipsis,
  Icons.search: CupertinoIcons.search,
  Icons.cancel: CupertinoIcons.clear,
  Icons.chevron_right: CupertinoIcons.chevron_right,
  Icons.delete_outline: CupertinoIcons.delete,
  Icons.clear: CupertinoIcons.clear,
  Icons.swap_horiz: CupertinoIcons.arrow_2_squarepath,
  Icons.fullscreen: CupertinoIcons.fullscreen,
  Icons.fullscreen_exit: CupertinoIcons.fullscreen_exit,
  Icons.pause: CupertinoIcons.pause,
  Icons.play_arrow: CupertinoIcons.play_arrow,
  Icons.refresh: CupertinoIcons.refresh,
  Icons.chat_bubble_outline: CupertinoIcons.chat_bubble,
  Icons.chat_bubble: CupertinoIcons.chat_bubble_fill,
  Icons.lock_open: CupertinoIcons.lock_open,
};
