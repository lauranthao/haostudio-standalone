# SEAM-S7 — 打磨（S7，最后一腿）

基线：`feature/swift-2.0-backup @ d2edf40`。结果分支：`feature/swift-2.0-polish`。
验证：细看代码 + `ios/preflight_check.py` 全过。未编译验证（无 Swift 工具链，
按 chen 的规矩不打构建，等最终打包时验）。

## 三腿分工

- A 腿（`feature/swift-2.0-polish-plaza @ 19d1902`，已合）：歌单广场接真接口
  （`MusicPlaylistImportAPI.plaza`，网易/QQ/酷狗/酷我，单平台、不 fallback、
  无返回时诚实“暂无推荐”）；睡眠定时补后台重查（每次 position 更新 +
  `willEnterForeground` 再查；页脚按模式显示，不再印空倒计时）；本地文件
  音质徽标（AVAudioFile 读格式/采样率/位深 + 文件大小÷时长估码率；
  无损 ≥96kHz/24-bit = Hi-Res，其他无损 = FLAC，有损 ≥320kbps = 320k，
  其余 honest“本地”；本地文件永远不标 Master）。
- B 腿（未提交，协调员合腿时落盘）：Xcode test target `HAoStudioTests`
  （host app，`@testable import HAoStudio`，17 个测试文件：B 接的 16 个 +
  协调员补注册的 A 腿 `MusicS7PolishTests.swift`）+ 死代码清理（见下）。
- C 腿（未提交，协调员合腿时落盘）：unslop 九项 + impeccable 全 app
  UI 走查（只读代码，无截图、无模拟器）+ 小接线（scenePhase →
  `handleBackground`/`handleForeground`；MPV `setAudioOnly` video=no）。

## B 腿：测试 target 与清理（协调员已逐项核对）

- `HAoStudioTests`：`com.apple.product-type.bundle.unit-test`，host app，
  `TEST_HOST` + `BUNDLE_LOADER`，bundle id `com.haostudio.standalone.tests`，
  部署目标 17.0、SWIFT_VERSION 5.0、TARGETED_DEVICE_FAMILY 1,2 与 app 一致；
  Sources phase 含 17 个测试文件；`Package.swift` 原样未动（SwiftPM 目标不变）。
  测试总数：164 个 `func test`（B 接的 16 文件）+ A 腿 11 个
  （`MusicS7PolishTests` 9 + `sleepStatusText` 2）= **175 个已写，未运行**。
- 删（全仓 grep 零代码引用，协调员复核过）：`VodPlayerViewModel.swift`
  （整文件 + pbxproj 4 处引用）、`VodGestureOverlayView` + `vodGestures(_:)`
  （`VodGestureState`/`VodGestureMath`/`VodGestureConfig` 保留，仍在用）、
  `EmbyReminder` 枚举、`LiveJSONFetcher` typealias、`StoredFileRef` 结构。
  `docs/storage-mapping.md:228` 的 `[StoredFileRef]` 旧文已过期，未动（S1 文档）。
- 协调员合腿时修的两处：
  1. `MusicSleepTimerTests.swift`：A 腿版（+2 个新测试）与 B 腿版（import 改线）
     撞文件——取 A 版内容、import 改为 `@testable import HAoStudio`。
  2. **画面比例 key 错配（真 bug）**：`SettingsStore.videoFit` 写
     `hao_vod_video_fit`（S1 迁移表 + storage-mapping.md 的权威键），而
     播放器内 `VodSettingsSheet` 读写 `hao_vod_fit`——设置页的画面比例开关
     与播放器内画面比例是两套 key，设置改了播放器收不到。已把
     `VodSettingsSheet` 两处改成 `hao_vod_video_fit`；全仓已无 `hao_vod_fit`。

## C 腿：UI 走查结果

- 方向五行：安静、精确、不抢戏；深夜客厅里的播放器（磨砂玻璃、荧幕微光、
  封面）；浓彩只在封面与画面；签名 = 磨砂玻璃底栏 + 红色 LIVE 点。
- unslop：轻度 slop，Polish 模式。修了：✓ 改 SF checkmark、专辑名 19→20pt、
  行 LIVE 徽标统一 10pt、6 处开发黑话改用户语言、迷你播放器真封面。
  未动：`.padding(.horizontal, 14)` 全 app 一致的页边距系统、`.bottom, 90/92`
  底栏+迷你播放器叠加高度、黑幕/封面同色明暗渐变、Splash 红点（spec 钉死）。
- impeccable：`impeccable context` 跑成功；`detect --json` 两遍都是 `[]`。
  LIVE 徽标白字对比度约 3.9:1（低于 4.5:1），liveRed 是 chen 钉死的唯一红，未改。
- 小接线两项都接上：scenePhase 前后台（启动 inactive→active 过渡是 no-op，
  因 session 只在 playing/buffering/loading 时进后台）；MPV `setAudioOnly`。
  AVPlayer/IJK 的 `setAudioOnly` 未接（仍走 `as?` 失败分支，只记标志）。

## 诚实局限与未决项（留给最终整合 / chen 定夺）

- **未编译验证、测试未运行**（无 Swift 工具链；按规矩不打构建，等最终打包时验）。
  打包前必须验：`xcodebuild test -scheme HAoStudio` 能否跑通 175 个测试
  （仓库里没有共享 scheme 文件，依赖 Xcode 自动生成）；Codemagic 目前只有
  `swift test` + Release 构建，没有 `xcodebuild test` 步骤（是否加由主 agent 定）。
- **12+ 个设置键没有任何读取方**（B 腿逐个核对过）：`mixWithOthers`、
  `autoResume`、`doubleTapSeconds`、`hideSynopsis`、`blurUnwatchedPosters`、
  `audioOnlyBackground`、`superResolution`、`interpolation`、`sdrToHDR`、
  `dvP8Downgrade`、`skipIntroMode`、`subtitleFontSize/Color/Position`、
  `lowMemoryMode`、`cellularDowngrade`。设置页有开关、行为层没人读——
  是补消费方、还是下版本再动，等 chen 定夺。**`audioOnlyBackground`
  尤其要产品决定**：关掉时后台是暂停还是继续播音频（C 腿也没接，原因相同）。
- **方案 §十 S7 里本次没做的项**（不在 S7 任务书范围，主 agent 定夺）：
  Home 页（真实数据聚合；首页 tab 目前仍是占位页，只改了文案）、
  全局搜索（三域适配器 + 聚合页）、统一播放协调（三域互斥）、ATS 收窄落地、
  iPad 适配、`PrivacyInfo.xcprivacy`、120Hz 真机 FPS 实测 + 遥测
  （本机无真机、无构建，不可能在本机做）。
- 直播推荐区仍是空态（无任何 `LiveDataGateway` 实现，做适配器是新功能）。
- 歌单广场接口是平台直连（随时可能变）；本地 FLAC 探测依赖 AVAudioFile
  对 FLAC 的 formatID 上报，未在真机文件上实测过（读失败只显示“本地”，
  不崩、不谎标）。
- 备份 zip 超 4 GiB 拒绝写入（无 ZIP64，S6 遗留）；`live_recordings/` 与
  `logs/` 在 Swift 侧尚无写入方（S6 遗留）；导入快照无清理入口（S6 遗留）。
