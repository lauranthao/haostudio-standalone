# SEAM-S5 — 设置 / 我的（S5）

基线：`feature/swift-2.0-live @ bb91662`。结果分支：`feature/swift-2.0-settings`。
验证：细看代码 + `ios/preflight_check.py` 全过。未编译验证（无 Swift 工具链，
按 chen 的规矩不打构建，等最终打包时验）。

## 三腿分工

- A 腿：设置引擎。`SettingsStore`（全部设置项的 @Published 状态，UserDefaults
  直写）、`ProfileStore`（本地昵称/头像，`hao_profile_nickname`）、`WallpaperStore`
  （壁纸，`hao_wallpaper_*`）、`CacheManager`（异步清理/统计，completion 在主线程）、
  `VideoEngineReporter`（播放内核上报）。Theme 相关状态只存在 `ThemeStore`，
  `SettingsStore` 只转发（`glassIntensity` / `tabAccent` / `accentOverride`），
  不许两处各存一份。
- B 腿：设置页 UI（`SettingsGroupsView`，7 组）+ 源管理页
  （`SourceManagementViews`：LX / CMS / 直播）+ Emby 配置页 UI
  （`EmbyConfigView` / `EmbyConfigViewModel`）+ 带 token 的 Emby 海报加载器
  （`EmbyImageLoader` / `EmbyPosterImage`）。纯逻辑抽在 `SettingsLogic.swift`
  （Foundation-only，进 AppCore 供 `swift test`）。
- C 腿：我的页（`MyView`，8 个入口带真实数量）+ App 壳接线
  （`MainTabView` 注入 `SettingsStore`、三层背景优先级 壁纸 > 背景色 > 主题、
  `GlassTabBar` 传 `tabAccent`）。

## 关键契约（S6 备份 / S7 打磨要用到）

- 自定义 accent 只有 ONE 个存储键：`hao_tabbar_accent`（ARGB 带透明度，
  Flutter 原样）。`accentOverrideHex` 是它的不透明视图，不是第二个键；
  `tabAccentColor` 是带透明度的 Color 视图。紫色 guard（`clampAccentHue`）
  在每次写入和加载时都跑。
- Emby 凭证：地址/用户名进 UserDefaults（`EmbyConfigStore`），apiKey 只进
  Keychain（`KeychainStore.saveEmbyApiKey`），永不进 UserDefaults、日志、测试。
  海报 URL 缺 api_key 时由 `EmbyImageLoader` 补 token（S3 的 401 债在此还）。
- S5 新增的 UserDefaults 键（S6 备份导出必须覆盖）：`hao_glass_intensity`、
  `hao_tabbar_accent`、`hao_profile_nickname`、`hao_wallpaper_*`、
  `hao_bgcolor_*`、`hao_music_normalization_*`、`hao_live_*`、`hao_video_*`、
  `hao_vod_*`、`hao_low_memory_mode`。`haoGlassIntensity` 从未进 S1 迁移表，
  全新安装从 1.0 开始。
- 测试：`Tests/SettingsTests/`（`SettingsGroupsLogicTests`，16 个）已接线进
  Package.swift（`SettingsTests` target，测 `SettingsLogic` 纯逻辑）。
  `Tests/SettingsUITests/`（SettingsStore / Emby / cache / My 页）未接线，
  等 S7 的 Xcode test target——与 MusicFeaturesTests / VideoPlayerTests
  同一先例，不许编造“测试通过”。
- `SettingsStore.glassIntensity` 是计算转发（get/set 到 ThemeStore），
  SwiftUI 里不许写 `$settings.glassIntensity`，用显式 Binding。
- `CacheManager.clearAll` / `totalSizeBytes` 都是异步（completion 在主线程），
  刷新尺寸必须等 clear 的 completion 回来再读。

## 诚实局限

- 未编译验证，等最终打包时验。
- 会员入口只有 alert 说明（不在 2.0 范围）；备份/恢复 UI 和在线更新 UI
  不在 S5（S6 做）。
- 壁纸文件路径存在 UserDefaults（`hao_wallpaper_paths`），文件本身在
  Documents——S6 备份要同时处理路径和文件，见 S6 范围。
