# SEAM-WIRING — 死设置开关补接线（chen 2026-11-23 21:26 定：补上接线）

基线：`feature/swift-2.0-polish @ 552853a`。结果分支：`feature/swift-2.0-settings-wiring`。
验证：细看代码 + `ios/preflight_check.py`（主 agent 跑）。未编译验证（无 Swift
工具链，等最终打包时验）。未触发任何构建、未打任何包。

## 两腿

- A 腿：影视播放器 12 键。`Services/Video/VodPlaybackSettings.swift`（新建，
  纯逻辑，Foundation-only，已进 AppCore——`Services/Video` 目录本就在
  AppCore sources 里，无需改 Package.swift）+ `VideoDriver` /
  `MpvPlayerBackend` / `PlayerKernel`（两个新能力协议）/ `VodGestures` /
  `VideoModels`（`PlayEpisode` 加 intro/credits 字段）/ `EmbyClient`
  （markers 不再丢弃）/ `VideoPlayerView` / `VideoDetailView` /
  `HAoStudioApp`（scenePhase 接 videoPlayer）/ `SettingsGroupsView`
  （三元互斥锁定 + 脚注修正）。
- B 腿：音乐/直播/应用 4 键 + 16 键核对表。`SettingsLogic.swift`（
  `LowMemoryModeEffect` / `LiveCellularDowngrade` / `AutoResumeDecision`）、
  `NativeMusicPlayer.applyMixWithOthers`、`MusicPlayerViewModel`（启动续播）、
  `LiveDriver`（进房间降档 + getifaddrs 网络判断）、`MpvPlayerBackend.open`
  （低配属性集）、`VideoDriver.reopenEpisodeAtCurrentPosition`、
  `VideoPlayerView`（lowMemory onChange）、`SettingsStore`（cellular 默认
  false→true，跟 Flutter 一致）。

## 合腿（协调员亲自做）

- 4 个重叠文件（SettingsGroupsView / VideoPlayerView / MpvPlayerBackend /
  VideoDriver）：**教训：`diff3 -m` 的参数顺序是 MYFILE OLDFILE YOURFILE，
  第一次传成 (base, A, B) 等于拿 A 当祖先，冲突数虚高（VideoPlayerView
  11 处假冲突）。改用 `git merge-file -p A文件 BASE文件 B文件` 重做，
  VideoDriver 零冲突、VideoPlayerView 只剩 3 处真冲突，逐处手合。**
  合完验证：两文件与 A 版 diff 只剩 B 的改动、与 B 版 diff 只剩 A 的改动；
  4 文件括号全部平衡；新类型全仓各只声明一次；VideoDriver 实现协议 5
  个新方法齐全。
- pbxproj 注册（`/tmp/register_wiring.py`，断言全过）：`VodPlaybackSettings.swift`
  进 app target（fileRef 1D1 / buildFile 1D2）、`WiringBehaviourTests.swift`
  进 HAoStudioTests target（fileRef 1D3 / buildFile 1D4）。`VodPlaybackSettingsTests`
  与 `WiringLogicTests` 在 `Tests/SettingsTests/`（SwiftPM 目标，pbxproj 不管）。
- preflight 文件数期望 144→145（只多 1 个 app 文件）。

## 16 键接线结果（合腿后全仓重 grep，不是腿的中途快照）

| 键 | 结果 |
|---|---|
| doubleTapSeconds | ✅ 接上。双击左 1/3 后退、右 1/3 前进 N 秒（5…30，默认 10），改设置下次双击即生效 |
| skipIntroMode | ✅ 接上。off/manual/auto3s/autoNow；Emby 章节标记优先，CMS 用自定义秒数；manual 显 pill，auto3s 倒计时 3s 后跳，autoNow 首次进窗口即跳；片尾 manual 显 pill、auto 进下一集 |
| subtitleFontSize/Color/Position | ✅ 接上（MPV only）。42/55/70、`sub-font-size`/`sub-color`/`sub-pos`；AVPlayer/IJK 静默 no-op |
| superResolution | ❌ 接不上。包里无 Anime4K shader，MPV 用 `vo=libmpv` 软件渲染，`glsl-shaders` 挂不上去。互斥解析仍排第一、设置页脚注已写明无实际效果 |
| interpolation | ✅ 接上（只保证属性发出）。`video-sync=display-resample` + `interpolation=yes` + `tscale=oversample`；`vo=libmpv` 下真机是否生效未验证 |
| sdrToHDR | ✅ 接上（只保证属性发出）。`inverse-tone-mapping=yes` + `tone-mapping=spline` + `target-trc=pq` + `target-peak=1000`；同上未验证 |
| dvP8Downgrade | ✅ 接上。开：P8 可走 AVPlayer；关：P8 只走 MPV/IJK；播中切换只对 AVPlayer 承载的 P8 流在当前位置重开 |
| hideSynopsis | ✅ 接上。详情页简介变占位，点按当次可见，重进恢复隐藏 |
| blurUnwatchedPosters | ✅ 接上。详情页未看封面 blur 18 + 点按查看；网格卡片不模糊（Flutter 一致） |
| audioOnlyBackground | ✅ 接上，但语义与 Flutter 有偏差（见下） |
| mixWithOthers | ✅ 接上。`NativeMusicPlayer.applyMixWithOthers`，init 读存量 + 开关 onChange 立即重设 audio session |
| autoResume | ⚠️ 接一半。启动自动续播接了（队列恢复后下一 runloop 起播）；**续播位置未接**：`saveResume` 全仓零调用，从没人存杀后台时的进度，续播从 0 开始 |
| cellularDowngrade | ✅ 接上（入口）。默认开（已改，跟 Flutter 一致）；移动网进房间压到超清及以下，失败回滚；房内即时切换无入口（设置页脚注本就写下次进房间生效） |
| lowMemoryMode | ✅ 接上。auto/always/never，auto=≤4 核；MPV only；开播时应用，播中改就地重开 |

## 额外发现：第 17 个死键 dialogueBoost（不在原 16 键内）

- Swift：只有 `VodSettingsSheet` 读存量值进自己的本地 state，没有任何后端
  接线——设置页开关点了没用。
- Flutter：`playback_session.dart:750`（`if (_dialogueBoost && next is
  DialogueBoostCapableBackend)`）+ 页面拥有开关状态，说明 Flutter 里是活的。
- 补接线做法（未做，等定夺）：照 Flutter 加 `DialogueBoostCapableBackend`
  能力 + `VideoDriver` 应用，小活，但两腿都没排进，需另定。

## 需主 agent 定夺（打最终包之前）

1. **audioOnlyBackground 语义**：Flutter 是“播放器内纯音频开关的默认值”
   （开则从打开起就是纯音频）；Swift 没有播放器内开关，A 腿按设置文案
   “纯音频后台播放”做了后台过渡语义——开：后台切纯音频继续播、回前台恢复
   画面；关：后台暂停、回前台保持暂停（Flutter 关时后台也是暂停，这点一致）。
   要不要以后补播放器内开关改回 Flutter 语义，或就按现在这个做。
2. **autoResume 续播位置**：补“杀后台存进度”需要定触发点（chen 有旧规矩：
   只在杀后台时存、仅后台不存；iOS 上无可靠的被杀回调）。不补则续播从 0 开始。
3. **dialogueBoost**：补不补（见上）。
4. **mixWithOthers 会被视频/直播盖掉**：`LiveDriver` 与 `VideoDriver` 打开时
   都 `setCategory(.playback, options: [])`。Flutter 没这个问题（just_audio
   从不重设 category）。要不要让两个 driver 也读本开关。

## 诚实局限

- 未编译验证、测试未运行（54 个新单测：A 24+8、B 15+7；全树 775 个）。
- interpolation / sdrToHDR 只保证属性发出，真机效果未验证。
- dvP8 重开失败会停播（先拆后端再解析；只在用户刚拨开关时触发）。
- cellular 房内即时切换与首选画质持久化（`preferResolution`）Swift 侧本来
  就没有入口，本次只接了设置页→下次进房间。
- 发布门守住了：没有任何 version.json 里有 2.0.0。
