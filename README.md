# HAo Studio 独立版

自包含的音乐 / 直播 / 视频 App：免费、无登录、无社区、无商店，所有流量走用户自己的网络（除更新检查外不连任何服务器），音源、影视源、直播源都可由用户自己管理。

当前版本：**v1.1.6（build 32）**

## 功能

- **音乐**：网易 / QQ / 酷狗 / 酷我多平台搜索（LX 音源脚本，用户可导入 .js、管理顺序）；iOS 用 AVPlayer 播放，自动切歌交叉淡入淡出；歌词在封面背后，点封面切换；10 段均衡器（iOS，挂在 AVPlayer 链上）；本地文件导入；歌单广场、排行榜、每日推荐、私人漫游与心动模式（全本地，用收藏和最近播放做种子）；睡眠定时（定时关 / 播完 N 首关 / 播完本首关）；音量归一化；书签 + 断点续播；变速不变调、淡入淡出、多队列、A-B 循环、歌词偏移 / 翻译、每日一 Pick、听歌报告、AutoEq、播放缓存；自动切歌音量、睡眠定时停播、解析窗口音画同步已修。
- **直播**：哔哩哔哩 / 斗鱼 / 虎牙 / 抖音 / 快手；三播放内核 MPV / IJK / AVPlayer，可切换、自动降级；多清晰度、多线路；弹幕（两级过滤、会话隔离、过期淘汰；描边/速度/最大数量/平台原色可调）；画质切换失败保旧画面；关注刷新、搜索渐进显示、移动网降档、纯音频 + 定时关、弹幕精细设置。
- **视频**：Apple CMS 影视源 + Emby（设置里填服务器地址和密钥，影视页可切换影视源 / Emby）；新增电影天堂、素博两个 CMS 源；Emby 添加页按账号登录重做（用户名 + 密码为主，API key 为高级选项）；豆瓣为唯一元数据来源（评分、演员、海报、简介），海报取最大档，缺图时按标题去 Bangumi / Bilibili 补高清海报；Infuse 风格详情页（顶部封面）；断点续播、历史记录、聚合「继续观看」；影视弹幕（默认关）；弹幕防遮挡（本机人物分割，仅 MPV，默认关）；跳过片头片尾、按住临时 2x、字幕时间偏移/字号/颜色/位置/双字幕；超分/插帧/SDR 转 HDR（仅 MPV、仅点播，默认全关）；Smart Groups 多版本合并；CMS 源上限 1080p，Emby 直连不限；播放器内设置面板（画质 / 弹幕 / 字幕等进播放器里改）；播放器控制栏消失已修。
- **外观**：4 套主题（苹果毛玻璃 / 暗夜鎏金 / 清新薄荷 / 极夜冰蓝）× 浅色 / 深色；液态玻璃强度滑块（0% 全透明也有字/图标阴影兜底）；壁纸与背景色全 app 生效；自定义强调色；苹果原生底栏（真 UITabBar）与迷你播放器；iOS 原生控件（glassy_ui_ios）与原生弹窗、开关（真 UISwitch）。
- **其他**：备份与恢复（导出 / 导入本地数据文件，zip）；在线更新（启动自动检查可开关，默认开）；iOS 原生感（滑动返回、按压变暗无波纹、原生弹窗/Toast/分段控件）；设置 7 组（按音乐 / 直播 / 影视域分组）可折叠；文字与按钮可读性修复（阴影与对比度）。

## 平台与安装

- **iOS**：v1.1.6 build 32，IPA 见 Gitee 发布页 https://gitee.com/chenhao030610/chen-hao-shop/releases（需自签名安装，如 LCSign / TrollStore）。
- **Android**：v1.1.5 build 25，分架构 APK（arm64-v8a / armeabi-v7a / x86_64），见商店 https://chen-hao-shop-production.up.railway.app。
- **Windows**：exeBuild 26，zip + 安装器，见商店 https://chen-hao-shop-production.up.railway.app。

## 构建

Flutter 3.47.0，Dart 3.13.0。

```sh
flutter pub get
flutter build ios --release --no-codesign   # iOS，未签名 IPA
flutter build apk --release --split-per-abi # Android APK
```

发布构建走 Codemagic（`codemagic.yaml`）：

- `iOS Flutter Unsigned IPA`：iOS 正式包，分支 main。
- `iOS Simulator App (Appetize)`：模拟器包（Appetize 测试用）。
- Android APK 在 haostudio-standalone-android 仓库，分支 android-apk。
- Windows 包在 haostudio-standalone-windows 仓库，走 GitHub Actions，分支 `feature/windows-port`。

## 分支

2026-11-22 起 iOS、Android、Windows 分三个仓库：本仓库只留 iOS 主线；Android 在 haostudio-standalone-android，Windows 在 haostudio-standalone-windows。

- `main`：默认分支，Flutter 开发主线。
- `master`：main 的副本（发布时同步）。
- `swift`：Swift v1.0.3，已冻结（2.0 Swift 重写已叫停）。
- `archive/master-swift-20261120`：旧 master 存档。

## 在线更新

App 内更新检查读 `version.json`：主地址是 Gitee raw（`https://gitee.com/chenhao030610/chen-hao-shop/raw/master/version.json`，国内直连），备用是商店 `https://chen-hao-shop-production.up.railway.app/version.json`。发版时 pubspec、代码里的版本号、三处 `version.json`（商店 public/、本仓库根目录、Gitee 仓库根目录）与 IPA 大小要一起改；IPA 附件挂在 Gitee Release 上。Windows 读单独的 `version-windows.json`（exeUrl / exeBuild / exeSize）。

## 版本历史

- **v1.1.6**：Emby 接入、影视弹幕与弹幕防遮挡、设置页 6 组平铺、音乐播放器下滑关闭、私人推荐/心动模式更智能、跳过片头片尾/按住 2x/双字幕、超分/插帧/SDR 转 HDR、Smart Groups、睡眠定时/音量归一化/书签、均衡器（iOS）、iOS 原生感。build 29：新增电影天堂、素博两个 CMS 源；音乐 12 项（变速不变调、淡入淡出、多队列、A-B 循环、歌词偏移/翻译、Smart Rules、每日一 Pick、Zap、听歌报告、AutoEq、播放缓存）；直播 15 项；苹果原生底栏与 iOS 原生控件；设置 6 组可折叠；Emby 添加页按账号登录重做；播放器内设置面板；文字可读性修复；音乐播放修复（自动切歌音量、睡眠定时停播、解析窗口同步）。build 30：删 Zap 发现与智能歌单；设置按域重组 7 组；音乐播放器进度条归零与卡死修复；Hive 损坏恢复与全局异常兜底；影视功能即时生效、直播画质切换修复；失效音源/影视源清理（LX 脚本 20→17、内置解析 15→10、CMS 源 19→18）；Emby 页重做（iOS 设置样式）+ 数据补全（媒体库全量、继续观看去重、分类页）；音乐/直播/设置大标题；按钮文字可读性与选中色修复；直播 chips 间距；VoiceOver 提示补全。build 31：弹幕设置闪退修复（错类型存储值强转兜底）；歌单行灰红透底修复（滑动操作条只在滑动时挂载）；Emby 分类 chips、backdrop 封面、已看状态同步、剧情介绍去重、继续播放卡片阴影对齐 Beans；全 app 卡顿优化（歌单行单遍着色器、直播骨架屏去多余模糊）；音乐拖进度条修复（拖完 5 秒未到目标即换新链接从拖到位置续播）；全 app 闪退排查两路（数据层约 389 处错类型强转加固 + 51 新测试；UI 层叠房间全屏控制器 + Emby 详情解析兜底）；UI 走查修复（无障碍提示、卡片阴影、golden 字体加载）。build 32：启动写迁移快照（每次启动把 app_settings 全量导出到 Documents/migration_snapshot.json，带逐键类型标签，供 Swift 2.0 首次启动迁移；写失败静默重试，不打扰用户）。
- **v1.1.5**：底栏 Kumone 玻璃样式、自定义强调色、歌单导入、液态玻璃强度滑块、壁纸全 app 生效、音乐播放器新颜、Master 徽章诚实校验、直播 IJK 断流修复。
- **v1.1.4**：私人漫游、心动模式、mini 播放器全音乐区可见、在线更新改走 Gitee。
- **v1.1.3**：系统音量、直播恢复、点播自动下一集。

## 原则

- 没有登录界面：任何需要平台登录的功能都不做（评论只读、点赞只存本地）。
- 独立版不用 TMDB：元数据只用豆瓣（商店网站仍用 TMDB）。
- 直连优先：音视频流直接走 CDN，只有浏览器连不上的接口调用才走服务器中转。
- 播放解析：按速度串行问源，第一个能播的地址立刻播，不为等更高音质拖延；没有目标音质就立刻降一档播。
- 发版规则：大更新换版本号，不只升 build 号；每个发布提交同步更新本 README，只写已做的功能。

## 致谢

- [Pure Live](https://github.com/liuchuancong/pure_live)：直播与播放器内核的功能与界面参考，MPV 内核移植来源。
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)：音乐播放逻辑参考（先停旧、带身份取 URL、切歌丢弃过期 URL）。
- 歌一刀：音源脚本与播放解析思路来源。
- [media_kit](https://github.com/media-kit/media-kit)（Predidit fork）：MPV 播放后端。
- [Anime4K](https://github.com/bloc97/Anime4K)（MIT）：实时超分着色器。
- Kumone / Beans：界面设计值参考（圆角、间距、阴影、动效）。

本仓库公开，无 LICENSE 文件。
