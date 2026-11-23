# HAo Studio 2.0 — Flutter 存储 → Swift 存储映射

2.0 不再用 Hive。设置进 UserDefaults，集合/索引用 Documents 下的 Codable JSON
文件。键名尽量沿用 Flutter 的 Hive 键名，只换存储机制，这样对照与迁移都有
据可查。来源：Flutter build 31（`lib/core/storage/hive_store.dart`、
`lib/core/theme/theme_controller.dart`、`lib/core/storage/local_paths.dart`、
`lib/core/theme/appearance_store.dart`，HEAD 2ef902b，1.1.6+31）。

## 规则（铁律 7）

- 只存相对名：文件索引里存 `<subdir>/<file>`，绝不存绝对路径。iOS 每次重装都
  换容器 UUID，绝对路径会死；加载时先修后删，删前必须重扫目录（见
  `ios/HAoStudio/Storage/LocalStore.swift` 的 `LocalFileIndex`）。
- 旧绝对路径条目：加载时按 Flutter `LocalPaths` 同样的三级顺序解析——
  （1）绝对路径仍存在则直接用；（2）`<当前 Documents>/<subdir>/<basename>`；
  （3）都没有才算丢失；丢失前先重扫目录，磁盘上有同名文件就保留。
- 损坏的索引文件不许让启动崩溃：解码失败返回默认值（`LocalStore.loadCollection`）。

## 设置：Hive box `app_settings` → UserDefaults

| Flutter Hive 键 | 类型 / 默认 | Swift 位置 |
|---|---|---|
| `haoThemeId` | String，`appleGlass` | `ThemeStore.themeKey`（UserDefaults，值同为主题 rawValue） |
| `haoThemeMode` | String，`system` | `ThemeStore.modeKey`（UserDefaults，`system` / `light` / `dark`） |
| `hao_custom_font_family` | String，`''` = 系统字体 | 后续 slice：自定义字体时再接 UserDefaults 同名键 |
| `videoPlayerKey` | String，`'mpv'`（Flutter 侧默认值；2.0 默认内核按 chen 2026-11-23 决定走能力分流，见方案 §四） | 后续 slice：播放器内核选择器（视频/直播专用；音乐永远 AVPlayer，不走这个键） |
| `engineSectionExpanded` | bool，`false` | 后续 slice：设置页播放器区展开状态 |
| `playbackSectionExpanded` | bool，`false` | 后续 slice：设置页播放设置区展开状态 |
| `hapticsEnabled` | bool，`true` | 后续 slice：触感反馈总开关 |
| `audioMixWithOthers` | bool，`false` | 后续 slice：与其他音频同时播放（AVAudioSession） |
| `autoResumeLastPlayback` | bool，`false` | 后续 slice：启动时自动续播上次歌曲（只读杀后台时存的进度） |
| `hao.audio.targetQuality` | —（2.0 新增） | `PlaybackCoordinator.targetQualityKey`（UserDefaults；目标音质保留到下一首，低一档播出时不覆盖它） |

## 集合/索引：Hive 同名数据 → Documents 下 JSON 文件

Flutter 侧这些集合原来存在 Hive box 里、值是相对名（`local_paths.dart` 已改
为相对名存储）；2.0 直接用 JSON 文件，文件名即集合名，内容为相对名数组
（`[StoredFileRef]`，见 `LocalStore.swift`）。

| Flutter 集合（子目录） | Swift JSON 文件 | 说明 |
|---|---|---|
| 本地音乐 `local_music/` | `Documents/local_music.json` | 导入的本地音乐文件索引 |
| 下载 `downloads/` | `Documents/downloads.json` | 下载文件索引 |
| 壁纸 `wallpapers/` | `Documents/wallpapers.json` | 自定义壁纸索引（`appearance_store.dart` 的 `kWallpaperSubdir`） |
| 自定义字体文件 | `Documents/fonts.json` | 用户安装的字体文件索引（后续 slice） |
| 歌单/收藏 | `Documents/favourites.json` | 点赞只存本地（无登录，不同步平台账号） |
| 播放进度（杀后台才存） | `Documents/playback_resume.json` | 只在杀后台时写，前台回前台不写、不 seek |

## 迁移（S1，本文档原“不迁移”结论作废）

> **作废说明（S0，2026-11-23）：** 本节原先写“2.0 是全新安装的地基，不做
> Hive → Swift 的自动迁移……2.0 首次启动即为空状态”。该结论与 chen 的硬
> 要求（用户数据零丢失）直接冲突，**作废**。迁移方案按 2.0 方案 §五执行，
> 三条路并行（S1 做）：
>
> - 路 A（主路）：Flutter 1.1.6.x 小版本先发，启动时把 `app_settings` 全量
>   导出为类型化 JSON 快照（`Documents/migration_snapshot.json`）；Swift
>   2.0 首次启动读快照、按本映射表写入、逐键计数校验，通过才标记
>   `migrationDone`。
> - 路 B（兜底）：现有备份 JSON（schema=1）导入，与 Flutter 侧逻辑一致
>   （先校验 envelope、快照当前、逐条写、失败全量回滚）。
> - 路 C（验证）：Hive 只读解析探针，证明快照没有漏键；探针不随 app 发布。
>
> 删前必有备份；不删 Hive box，直到迁移验证通过且用户已正常使用 2.0 一段
> 时间；删除只由用户在设置页手动触发。发布门：S6 备份导入 + 跨代迁移测
> 试通过之前，不许把 2.0.0 写进任何 `version.json`。
