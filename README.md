# HAo Studio 独立版

自包含的音乐 / 直播 / 视频 App：免费、无登录、无社区、无商店，所有流量走用户自己的网络（除更新检查外不连任何服务器），音源、影视源、直播源都可由用户自己管理。

当前版本：**v1.1.6（build 28）**

## 功能

- **音乐**：网易 / QQ / 酷狗 / 酷我多平台搜索（LX 音源脚本，用户可导入 .js、管理顺序）；iOS 用 AVPlayer 播放，自动切歌交叉淡入淡出；歌词在封面背后，点封面切换；10 段均衡器（iOS，挂在 AVPlayer 链上）；本地文件导入；歌单广场、排行榜、每日推荐、私人漫游与心动模式（全本地，用收藏和最近播放做种子）；睡眠定时（定时关 / 播完 N 首关 / 播完本首关）；音量归一化；书签 + 断点续播。
- **直播**：哔哩哔哩 / 斗鱼 / 虎牙 / 抖音 / 快手；三播放内核 MPV / IJK / AVPlayer，可切换、自动降级；多清晰度、多线路；弹幕（两级过滤、会话隔离、过期淘汰；描边/速度/最大数量/平台原色可调）；画质切换失败保旧画面。
- **视频**：Apple CMS 影视源 + Emby（设置里填服务器地址和密钥，影视页可切换影视源 / Emby）；豆瓣为唯一元数据来源（评分、演员、海报、简介），海报取最大档，缺图时按标题去 Bangumi / Bilibili 补高清海报；Infuse 风格详情页（顶部封面）；断点续播、历史记录、聚合「继续观看」；影视弹幕（默认关）；弹幕防遮挡（本机人物分割，仅 MPV，默认关）；跳过片头片尾、按住临时 2x、字幕时间偏移/字号/颜色/位置/双字幕；超分/插帧/SDR 转 HDR（仅 MPV、仅点播，默认全关）；Smart Groups 多版本合并；CMS 源上限 1080p，Emby 直连不限。
- **外观**：4 套主题（苹果毛玻璃 / 暗夜鎏金 / 清新薄荷 / 极夜冰蓝）× 浅色 / 深色；液态玻璃强度滑块（0% 全透明也有字/图标阴影兜底）；壁纸与背景色全 app 生效；自定义强调色；原生液态玻璃底栏与迷你播放器。
- **其他**：备份与恢复（导出 / 导入本地数据文件，zip）；在线更新（启动自动检查可开关，默认开）；iOS 原生感（滑动返回、按压变暗无波纹、原生弹窗/Toast/分段控件）。

## 平台与安装

- **iOS**：v1.1.6 build 28，IPA 见 Gitee 发布页 https://gitee.com/chenhao030610/chen-hao-shop/releases（需自签名安装，如 LCSign / TrollStore）。
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
- `Android APK`：分支 android-apk。
- Windows 包走 GitHub Actions，分支 `feature/windows-port`。

## 分支

- `main`：默认分支，Flutter 开发主线。
- `master`：main 的副本（发布时同步）。
- `android-apk`：Android APK 线。
- `feature/windows-port`：Windows 电脑版。
- `swift`：Swift v1.0.3，已冻结（2.0 Swift 重写已叫停）。
- `archive/master-swift-20261120`：旧 master 存档。

## 在线更新

App 内更新检查读 `version.json`：主地址是 Gitee raw（`https://gitee.com/chenhao030610/chen-hao-shop/raw/master/version.json`，国内直连），备用是商店 `https://chen-hao-shop-production.up.railway.app/version.json`。发版时 pubspec、代码里的版本号、三处 `version.json`（商店 public/、本仓库根目录、Gitee 仓库根目录）与 IPA 大小要一起改；IPA 附件挂在 Gitee Release 上。Windows 读单独的 `version-windows.json`（exeUrl / exeBuild / exeSize）。

## 版本历史

- **v1.1.6**：Emby 接入、影视弹幕与弹幕防遮挡、设置页 6 组平铺、音乐播放器下滑关闭、私人推荐/心动模式更智能、跳过片头片尾/按住 2x/双字幕、超分/插帧/SDR 转 HDR、Smart Groups、睡眠定时/音量归一化/书签、均衡器（iOS）、iOS 原生感。
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

本仓库私有，无 LICENSE 文件。
