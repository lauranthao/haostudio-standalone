# HAo Studio 独立版 2.0 — iOS 工程

Swift 原生重写（SwiftUI）：零网站连接，不登录、无商店、无社区、无后台，
所有流量走手机直连。没有旧的网页壳，没有打包进包的 web 前端，没有外部元数据服务。

## 工程结构

| 路径 | 说明 |
|---|---|
| `HAoStudio/HAoStudioApp.swift` | @main 入口（SwiftUI 生命周期，无 AppDelegate/SceneDelegate） |
| `HAoStudio/Theme/` | 主题系统：`HaoTheme.swift`（4 主题 × 浅/深色值，照 Flutter `hao_themes.dart` 取值、Swift 原生结构）、`ThemeStore.swift`（UserDefaults 持久化，切换立即全局生效） |
| `HAoStudio/App/` | `MainTabView.swift`（5-tab：首页/音乐/影视/直播/我的）、`GlassTabBar.swift`（悬浮玻璃底栏）、`MiniPlayerBar.swift`（迷你播放器 + 全屏播放器空态）、`Glass.swift`（liquid glass 兜底 + 悬浮布局常量）、`PlaceholderViews.swift`（占位页；我的页 = 设置页，主题切换已可用） |
| `HAoStudio/Playback/` | `PlaybackCoordinator.swift`（单音频协调器壳：同一时间一个声音；音乐 AVPlayer、点播/直播分流、串行解析的接口与规则注释，无引擎、无解析） |
| `HAoStudio/Storage/` | `LocalStore.swift`（设置 UserDefaults；集合/索引为 Documents 下 Codable JSON，只存相对名，加载先修后删、删前重扫） |
| `HAoStudio/Splash/` | `SplashView.swift`（启动动画 #4，按 `docs/splash-animation-4-spec.md`） |
| `HAoStudio/Assets.xcassets` | AppIcon + Logo（美术资产已定，不许改） |
| `HAoStudio/Base.lproj/LaunchScreen.storyboard` | 启动屏（空白白底，与启动动画首帧衔接） |
| `HAoStudio/Info.plist` | 显示名 `HAo Studio`；后台音频 `audio`；URL scheme `haostudio`；**无 SceneManifest**（SwiftUI @main 不需要 SceneDelegate） |
| `HAoStudio/HAoStudio.entitlements` | 故意空的——App Group 是付费团队才有的能力，免费证书装不上，必须保持空 |
| `HAoStudio.xcodeproj/` | 工程文件（1 个 target：HAoStudio；18 个 libmpv xcframework 引用，构建时下载，不在仓库里） |
| `preflight_check.py` | 预检脚本（引用存在性、资产 md5、Info.plist、启动动画数值、主题色值、codemagic 配置） |

## 关键约定

- **Bundle ID**：`com.haostudio.standalone`；显示名 `HAo Studio`；iOS 17.0；
  `UIBackgroundModes = audio`；`TARGETED_DEVICE_FAMILY = 1,2`；Swift 5.0。
- **主题**：4 主题（苹果毛玻璃/暗夜鎏金/清新薄荷/极夜冰蓝）× 浅色/深色。
  色值对照 Flutter `hao_themes.dart`；所有 UI 读环境里的 palette，不写死颜色。
  底栏选中态黑色（深色模式为白色，深色底上黑色看不见）；红色只用于 LIVE 徽标/录制点。
- **底栏**：系统 `UITabBar`（SwiftUI 里 `UIViewRepresentable` 桥接），iOS 26+
  用 `UIGlassEffect` 玻璃，iOS 17–25 回落系统默认毛玻璃背景；选中 pill 实色
  #E4E4E4（浅色）/ #3A3A3C（深色），选中图标+文字黑/白。
- **迷你播放器**：悬浮玻璃条，位于底栏上方；点它进全屏播放器（地基里是空态
  占位，不做假播放）。地基无播放引擎，当前无播放项时整条隐藏。
- **播放协调器**：同一时间只能有一个声音；音乐只用 AVPlayer；点播点播放直接
  横屏全屏，直播进房竖屏、只有 [] 按钮转横屏；音质选择器只在直播；解析串行、
  第一个能播立刻播。以上是接口与注释，引擎在播放器 slice 接。
- **存储**：设置 UserDefaults；集合/索引用 Documents 下的 Codable JSON 文件，
  只存相对名；对应关系见仓库根 `docs/storage-mapping.md`。
- **删掉的**：旧的网页壳、`web/` 前端（两份）、旧元数据服务的配置文件、旧 Widget/
  歌词扩展、Podfile/lock、旧 Swift 文件、外部元数据服务（独立版已不用，豆瓣是唯一
  元数据源）。

## 构建

`codemagic.yaml` 在仓库根，workflow `ios-unsigned`（mac_mini_m1，未签名 IPA）。
构建时下载 libmpv（Predidit 0.6.8，sha256 校验）到 `ios/Vendor/libmpv`；
无 Podfile 时 `pod install` 一步跳过（播放器 slice 加回 Podfile 后自动恢复）。

## 预检

`python3 ios/preflight_check.py`：工程引用、资产 md5、Info.plist 关键值、
Swift 括号平衡与禁用残留（旧网页壳/旧元数据服务/旧前端入口/旧文件名）、启动动画数值、
8 套主题色值、codemagic 配置。全部通过才算地基自查完成——**不代替编译**，
编译验证走 Codemagic，本阶段不触发构建。
