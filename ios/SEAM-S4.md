# S4 直播 — 三腿分工与缝合契约

chen 定：2.0 全部做完、合在一起、一次发给他，不再按切片发开发包。
S4 完成后不单独发包、不触发任何构建；协调员合三腿 → 注册进 Xcode 工程 →
preflight 全过 → 向主 agent 汇报，由主 agent 接力 S5。最后的包等 S7 之后统一打。

## 基线

- 分支 `feature/swift-2.0-live`，从 `6b914f2`（S3 完成点）起。
- App target SWIFT_VERSION = 5.0：**completion handler only，不许 async/await，不许 `any`**。
  SwiftPM 测试 target 同样守这条（app 源码两边共用）。
- 每次提交前必须跑 `ios/preflight_check.py`，全过才能提交。
- **三腿不许改 `project.pbxproj`、不许改 `Package.swift` 之外的共享文件。**
  新文件由协调员在合腿时统一注册进工程（S2 的教训：pbxproj 插入
  锚点必须以换行结尾，否则新行粘在原行尾、组解析串位）。
  唯一例外：B 腿改 `Package.swift`（加 LiveSites 目录 + LiveLibraryStore
  单文件 + LiveServicesTests / LiveFeaturesTests 两个 testTarget）。
- 直播只做 5 个平台：Bilibili、Douyu、Huya、Douyin、Kuaishou。
  其他 29 个 Pure Live 平台绝不加。

## 缝合点（三腿直接用，不许各发明一套）

- `Playback/PlaybackCoordinator.swift`（A 腿改）：`LivePlaybackDriver`
  协议（照 `VideoPlaybackDriver` 的形状：`currentRoom: PlaybackItem?`、
  `isPlaying`、`resolveURL`、`onRoomStarted` / `onRoomFailed`、`play` /
  `open` / `stop` / `resume` / `seek`）+ `liveDriver` 槽 +
  `requestLivePlay(_:)`（进直播先停音乐和 VOD）+ `stop()` 停三个域。
  `PlaybackKind.live` 已存在，直接用。
- `Services/LiveSites/LiveModels.swift`（B 腿定义）：`LiveRoom` /
  `LiveLine` / `LiveQuality` / `DanmakuMessage`。A、C 两腿只用，不许
  自己再定义一套。
- `Services/LiveSites/LiveDanmakuSettings.swift`（B 腿定义）：
  `LiveDanmakuSettings`（14 项）+ 默认值，Foundation-only，C 腿的
  设置 UI 用它。
- `LiveSiteResolver` 协议（B 腿定义）：`resolve(roomId:completion:)`、
  `roomInfo(roomId:completion:)`。A 腿的 session 通过它拿数据。
- `Playback/LivePlayerViewModel.swift`（A 腿定义）：播放器状态 + 全屏
  请求 + 亮度/音量状态。C 腿的房间页用它，不自己写播放器。
- `Features/Live/LiveLibraryStore.swift`（C 腿写，B 腿在 Package.swift
  里登记进 AppCore）：关注/历史/续播，LocalStore 持久化，
  Foundation-only，不许 import SwiftUI。

## 三腿分工

### A 腿 — 播放内核 + 房间状态机（clone `standalone-app-2.0-s4-kernel`，分支 `feature/swift-2.0-live-kernel`）

拥有：`Playback/LiveDriver.swift`（新建，用 PlayerKernel 能力分流，
不另起一套播放器）、`Playback/LiveRoomSession.swift`（新建，Foundation-only
状态机）、`Playback/LivePlayerViewModel.swift`（新建）、
`Playback/PlaybackCoordinator.swift` 的直播部分（只加，不改音乐/VOD 行为）、
`Tests/VideoServicesTests/LiveRoomSessionTests.swift`、
`Tests/VideoPlayerTests/LiveDriverTests.swift`（iOS-only，暂不接 SwiftPM，留 S7）。

- 恢复 fetch-and-hold：lease `refreshAt` 约 100s 取 fresh 攥着不切；
  恢复时先用 held、再 `fetchFresh()`（60s 节流、10s 超时）、再下一线路；
  `freshRounds=2` 有界；单线路房间先试一次 fresh 重解析再失败。
- 卡顿看门狗：4s 不动提示“重新连接”，12s 不动判失败进恢复。
- 后台音频只给直播：`setAudioOnly(true)` 停视频轨保音频；VOD 不走这条。
- 退出房间不自动恢复音乐。画质切换失败回滚旧画质（P0-09）。
- 亮度/音量只在直播播放器里，照抄 S3 VOD 的做法。

### B 腿 — 5 平台解析 + 5 弹幕传输（clone `standalone-app-2.0-s4-sites`，分支 `feature/swift-2.0-live-sites`）

拥有：`Services/LiveSites/` 全部、`ios/Package.swift`（唯一可改）、
`Tests/LiveServicesTests/` 全部。

- 5 平台解析 + 房间信息（标题/主播/在线人数/封面/是否直播）。
- 弹幕只收不发：Bilibili WS 二进制、Douyu `type@=` 文本、Huya TARS+WUP
  （60s 心跳）、Douyin protobuf（10s 心跳，手写最小解码器，不加
  SwiftProtobuf）、Kuaishou HTTP 轮询。
- TARS 手写 Swift，以 Flutter `lib/core/tars/` 为规约；先读
  `standalone-app-2.0-mpv` 的 TARS diff。P0-03：超时单位写清（秒，
  显式命名）、默认 6s；空响应抛错，不许 `value!`。
- 测试用录制 fixture，不许联网。

### C 腿 — 直播首页 + 房间页 UI（clone `standalone-app-2.0-s4-ui`，分支 `feature/swift-2.0-live-ui`）

拥有：`Features/Live/` 全部、`App/MainTabView.swift`（只改 `.live` 一行）、
`App/HAoStudioApp.swift`（只加 liveDriver 接线，照抄 vodDriver）、
`Tests/LiveFeaturesTests/` 全部。

- 首页：推荐直播、分类、搜索入口、关注行、历史行。
- 房间页：竖屏进（16:9 内嵌视频 + 信息 + 弹幕），只有 [ ] 按钮进横屏；
  转手机不横屏；横屏 = 整个 app 转，方向锁定开着也要能转。横屏机制
  照抄 S3 VOD。
- 画质/线路切换器、亮度/音量滑块（只在直播播放器里）、弹幕层 +
  弹幕设置（14 项）、在线人数、主播信息、关注按钮。
- 设计照 Pure Live 1:1；全部走主题变量；4 主题 × 亮/暗 8 组合；
  无紫色；红色只用在 LIVE 角标/录制点。

## 不许碰

- S5–S7 的东西（设置/My、备份/更新、Home 聚合、全局搜索、iPad）。
- 登录、智能歌单、实时活动。
- `version.json`、版本号、2.0.0 字样不许进任何文件。
- Hive box 与快照文件：不许删。
- 任何构建、任何包：S4 不触发 Codemagic、不打任何包，等 S7 之后统一打。

## 合腿检查（协调员逐条过）

- S3 教训 11 条逐条自查（见主 agent 任务书）。
- 三腿的模型名无冲突、无重复类型声明。
- B 腿的 Package.swift：一个文件只属于一个 target；exclude 在 sources 前面。
- 新文件全部注册进 pbxproj（锚点 = 组定义行 `= {isa = PBXGroup;`，
  收尾取两种缩进中最早的；插入行以换行结尾）。
- preflight 全过。向主 agent 汇报时明说“未编译验证，等最终打包时验”。
