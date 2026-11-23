# S3 影视 — 三腿分工与缝合契约

chen 定：2.0 全部做完、合在一起、一次发给他，不再按切片发开发包。
S3 完成后不单独发包；协调员合三腿 → 注册进 Xcode 工程 → preflight 全过 →
向主 agent 汇报，由主 agent 做内部编译验证并接力 S4。

## 基线

- 分支 `feature/swift-2.0-video`，从 `2214928`（S2 完成点）起。
- App target SWIFT_VERSION = 5.0：**completion handler only，不许 async/await，不许 `any`**。
  SwiftPM 测试 target 同样守这条（app 源码两边共用）。
- 每次提交前必须跑 `ios/preflight_check.py`，全过才能提交。
- **三腿不许改 `project.pbxproj`、不许改 `Package.swift` 之外的共享文件。**
  新文件由协调员在合腿时统一注册进工程（S2 的教训：pbxproj 插入
  锚点必须以换行结尾，否则新行粘在原行尾、组解析串位）。
  唯一例外：B 腿改 `Package.swift`（加 VideoServices target），A、C 腿不碰。

## 缝合点（已落进分支，三腿直接用，不许各发明一套）

- `Playback/PlaybackCoordinator.swift`：`VideoPlaybackDriver` 协议 +
  `vodDriver` 槽 + `requestVodPlay(_:)` + 互斥（播 VOD 先停音乐，
  播音乐先停 VOD；`stop()` 停两个）。VOD 的 PlaybackItem id 必须是
  `VideoResumeKey.episodeId(title:year:episodeName:)`。
- `Services/Video/VideoModels.swift`：`VideoSource` / `VideoItem` /
  `PlayEpisode` / `PlayLine` / `VideoMeta` / `VideoDetail` /
  `VideoResumeKey` / `ResumeInfo` / `VideoHomeRow`。字段名跟 Flutter
  `video_models.dart` 对齐；断点续播键是标题+年份（CMS vod_id 会漂移，
  不许拿它当续播键）。

## 三腿分工

### A 腿 — 播放器内核 + VOD driver（clone `standalone-app-2.0-s3-kernel`）

拥有：`Playback/PlayerKernel.swift`（新建：能力门禁 + 候选队列 +
降级梯子）、`Playback/MpvPlayerBackend.swift`、`Playback/IJKPlayerBackend.swift`、
`Playback/AVPlayerBackend.swift`、`Playback/Diagnostics.swift`、
`Playback/VideoDriver.swift`（实现 `VideoPlaybackDriver`）、
`Playback/VodPlayerViewModel.swift`、`Playback/VodGestures.swift`、
`Playback/VodSettingsSheet.swift`、`Playback/VodDanmakuLayer.swift`、
`Services/Video/VideoCapability.swift`（纯函数：格式门禁 + 内核排序，
可进 SwiftPM 测试）、`Playback/PlaybackCoordinator.swift` 的 evict
接线（见下）、`Tests/VideoServicesTests/VideoCapabilityTests.swift`、
`Tests/VideoPlayerTests/`（iOS-only 部分的测试，暂不接 SwiftPM，留 S7，
跟 S2 的 MusicPlayerTests 同一处理）。

- 能力门禁：FLV / MKV 绝不分 AVPlayer；AVPlayer 只接 HLS / MP4；
  优先级 MPV 100 / IJK 90 / AVPlayer 80；能力分流：HEVC / 杜比视界 /
  HLS / MP4 默认走 AVPlayer，FLV / MKV / ASS 字幕 / 多音轨走 MPV，
  IJK 第三选择。
- MPV：逐条设属性，被拒只记日志（不记值）、跳过继续；`hwdec=auto-safe`，
  open 成功后读回 `hwdec-current` 验证真生效；失败静默软解不许出现。
- IJK：显式 `videotoolbox=1` 并验证会话建立。
- 降级：验证为软解且片源是 4K HEVC / 杜比视界 → 自动切 AVPlayer 重开，
  同位置续播；软解但 AVPlayer 不能播的格式（FLV/MKV）在诊断里标明
  “软解中”，不静默。VOD 不丢帧、直播丢帧的策略分开（以 build 31
  `mpv_properties.dart` 为准核对）。
- Driver：episode/line 状态、换源后同一集同一位置续播、seek 用
  completion 回读校验失败回滚 UI、位置看门狗 4s 提示 / 12s 失败、
  退出时 await 释放（Task 取消 + deinit 路径等待，断点不丢）。
  `resolveURL` 闭包由 C 腿在 HAoStudioApp 里接到 B 腿的 CmsClient 上；
  A 腿只定义、不实现解析。
- Evict 接线（S2 遗留）：`PlaybackCoordinator.musicDriver.resolveURL`
  现在丢弃了 `excluding`（`{ item, _, completion in`）——改成透传给
  resolver；resolver 侧用 B 腿（S2）已暴露的 `evictPlayUrl` 丢弃已试
  URL，失败后试下一个候选，不许重复试同一个 URL。
- 参考：旧 Swift `~/workspace/deploy/standalone-app/ios/HAoStudio/`
  （PlayerKernel / MpvPlayerBackend / IJKPlayerBackend /
  NativePlayerViewController——只参考引擎行为，不抄 UI）、搁置 clone
  `~/workspace/deploy/standalone-app-2.0-mpv`（MPV 属性容错 + TARS，
  先读 diff 再翻译）、Flutter `lib/core/player/kernel/*`、
  `lib/core/player/vod_features.dart`、`lib/features/video/native_video_player_page.dart`
  （行为基线，4210 行——只读相关部分）。

### B 腿 — 服务层（clone `standalone-app-2.0-s3-services`）

拥有：`Services/Video/` 下除 `VideoModels.swift`、`VideoCapability.swift`
之外的全部文件、`Services/DownloadEngine/`、`ios/Package.swift`
（唯一可改 Package.swift 的腿）、`Tests/VideoServicesTests/`（除
`VideoCapabilityTests.swift` 之外）。

- `CmsClient.swift`：18 个默认源（以 `cms_sources.dart` 为准数，
  revision 5 删暴风后是 18 个——数出来写进提交说明；与 README 逐项
  对齐）、搜索 / 列表 / 详情 / 播放地址解析、串行最快优先、源管理
  （开关/排序/增删/恢复默认、至少留一个源、按修订号合并、用户删掉
  的源永不复活）、运行时测速（P0-11；做不到就注明静态并写清原因，
  不许假装测了）。
- `DoubanService.swift`：搜索 + 详情，年份校验 + 错配不永久缓存；
  全仓扫一遍确认无 TMDB 引用。
- `EmbyClient.swift`：服务器配置、AuthenticateByName 登录、媒体库、
  Genres 分类、影片/剧集、流地址；凭证只进 Keychain（已有
  KeychainStore）；剧情介绍去重（回归测试，build 31 已修过的 bug）。
- `DownloadEngine.swift`（音乐 + 影视共用）：真正下载 + 任务管理
  （排队/暂停/续传/取消/进度），落盘 `music_downloads/`（相对名，
  LocalStore 索引）；并把 S2 音乐页已有的下载按钮接到引擎上。
- S2 遗留的数据层：排行榜用现有 API 暴露（不许另起新协议——先找
  Flutter/LX 已有的排行接口）；评论/专辑/歌手 API（S2 已有
  MusicCommentsAPI/MusicAlbumAPI/MusicArtistAPI）核对可用并补齐 C 腿
  页面要的字段。
- 测试：CMS 解析用录制的 JSON fixture（测试里不许联网）、Douban
  年份校验、Emby 剧情去重回归、续播键、DownloadEngine 状态机
  （本地 file URL，不联网）。
- 参考：Flutter `lib/services/video/cms_client.dart`、
  `lib/features/video/cms_sources.dart`、`lib/services/video/douban_service.dart`、
  `lib/services/video/emby_client.dart`、`lib/services/video/emby_models.dart`、
  `lib/features/video/video_home_service.dart`、
  `lib/features/video/video_history_store.dart`。

### Package.swift（B 腿唯一可改，构建 #18 后的定稿）

- SwiftPM 不许一个源文件属于两个 target（构建 #18：MigrationCore
  占整个 Storage 目录，MusicLX 又单列了 LocalStore + KeychainStore）。
  music 分支已修成一个 AppCore（09b05e4）；S3 完成后协调员把 music
  分支合并进 video 分支带过来。
- B 腿不许新建 VideoServices target，更不许在新 target 里列
  PlaybackCoordinator.swift 或任何 Storage 文件。只做两件事：
  MusicLX target 的 sources 加上 `"Services/Video"` 与
  `"Services/DownloadEngine"`；加一个 VideoServicesTests testTarget
  （path `Tests/VideoServicesTests`，dependencies `["MusicLX"]`）。
  合腿时协调员把该 testTarget 改指 AppCore，并把两个目录补进
  AppCore 的 sources。
- 不许动 MigrationCore、不许动 MusicLX 已有的 Storage 两条、不许
  改名、不许改 defaultLocalization（已在 669ea87）。

### C 腿 — 功能 UI（clone `standalone-app-2.0-s3-features`）

拥有：`Features/Video/` 全部、`Features/Music/` 的评论/专辑/歌手/
排行页面 + MusicTrack 徽标、`App/MainTabView.swift`（影视 tab 接线）、
`HAoStudioApp.swift`（vodDriver + resolveURL 接线）、
`Tests/VideoFeaturesTests/`（暂不接 SwiftPM，留 S7，跟 S2 的
MusicFeaturesTests 同一处理）。

- 影视 tab：首页（行数据来自 CmsClient + Douban）、分类、搜索、
  详情页、选集/线路、历史、收藏。
- 详情页顶部必须是封面（Infuse 风格 + 渐变/淡入动画），去掉中间的
  大播放键；播放靠下面的大蓝按钮（▶ 第01集）和选集。
- 播放器页：点播放直接横屏全屏；无画质选择器（VOD 绝不许有假画质
  按钮）；长按 2x 仅 VOD；进度条从开播就有；换源后同一集同一位置续播。
- `VideoLibraryStore`：历史/收藏/断点续播持久化（LocalStore），
  续播键用 `VideoResumeKey`。
- Emby tab + 详情 + 分类（Genres chips）。
- S2 遗留 UI：评论只读页、专辑详情页、歌手详情页、排行榜页（用
  S2 已有 API，不许另起新协议）；MusicTrack 平台徽标：LX 结果带
  真实平台信息，不要让 lx: 结果一律显示“网易”。
- 下载按钮（影视详情页）接到 B 腿的 DownloadEngine。
- 设计：全部走主题变量，不许写死颜色；4 主题 × 亮/暗 8 组合；无紫色；
  红色只用在有意义处。8 组合截图需真机，本地做不了就明说。
- 参考：Flutter `lib/features/video/video_tab_page.dart`、
  `video_detail_page.dart`、`video_search_page.dart`、
  `video_favs_page.dart`、`video_history_page.dart`、`video_type_page.dart`、
  `emby_tab_page.dart`、`emby_detail_page.dart`、`emby_category_page.dart`、
  `video_poster_card.dart`。

## 不许碰

- S4–S7 的东西（直播、设置/My、备份/更新、Home 聚合、全局搜索、iPad）。
- 歌单广场（需要合同外不存在的 LX 广场 API，留 S7）。
- 睡眠定时结束检测启发式、本地文件音质徽标显示“—”（留 S7）。
- 4 个重度混淆脚本（aya、molan、yuningxi、fish）永久不捆绑——无法
  审计 key，用户自导入兜底（已定，不许改）。
- `version.json`、版本号、2.0.0 字样不许进任何文件。
- Hive box 与快照文件：不许删。

## 汇报

每腿汇报：分支、提交列表、改动文件、preflight 结果、跑过的测试与
结果、诚实局限、仍是占位的东西。只说验过的东西；没验过的明说没验过。
