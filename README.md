# HAo Studio 独立版

自包含的音乐 / 直播 / 视频 App：免费、无登录、无社区、无商店，所有流量走用户自己的网络（除更新检查外不连任何服务器），音源、影视源、直播源都可由用户自己管理。

当前版本：**v1.1.2（build 13）**

## 功能

- **音乐**：网易 / QQ / 酷狗 / 酷我多平台搜索（LX 音源脚本，用户可导入 .js、管理顺序）；AVPlayer 播放，自动切歌交叉淡入淡出；歌词在封面背后，点封面切换；均衡器（10 段）；本地文件导入与下载；歌单广场、排行榜、每日推荐。
- **直播**：哔哩哔哩 / 斗鱼 / 虎牙 / 抖音 / 快手；三播放内核 MPV / IJK / AVPlayer，可切换、自动降级；多清晰度、多线路；弹幕。
- **视频**：Apple CMS 影视源；豆瓣为唯一元数据来源（评分、演员、海报、简介）；Infuse 风格详情页（顶部封面）；断点续播、历史记录。
- **外观**：4 套主题（苹果毛玻璃 / 暗夜鎏金 / 清新薄荷 / 极夜冰蓝）× 浅色 / 深色；原生液态玻璃底栏与迷你播放器。
- **其他**：备份与恢复（导出 / 导入本地数据文件）；在线更新；120Hz。

## 平台与安装

- **iOS**：已发布，IPA：https://chen-hao-shop-production.up.railway.app/HAoStudio-standalone-v1.1.2.ipa（需自签名安装，如 LCSign / TrollStore）。
- **Android**：APK 进行中（分支 `android-apk`），发布后链接放这里。

## 构建

Flutter 3.47.0，Dart 3.13.0。

```sh
flutter pub get
flutter build ios --release --no-codesign   # iOS，未签名 IPA
flutter build apk --release                 # Android APK
```

发布构建走 Codemagic（`codemagic.yaml`）：

- `iOS Flutter Unsigned IPA`：iOS 正式包，分支 main。
- `iOS Simulator App (Appetize)`：模拟器包（Appetize 测试用）。
- `Android APK`：进行中。

## 分支

- `main`：Flutter 线（iOS 已发，Android 在做），当前开发主线。
- `master`：Swift v1.0.3（已冻结；2.0 Swift 重写已叫停）。
- `android-apk`：Android APK。

## 在线更新

App 内更新检查读 `version.json`：主地址是商店 `https://chen-hao-shop-production.up.railway.app/version.json`，备用是 GitHub raw。发版时 pubspec、代码里的版本号、两处 `version.json` 与 IPA/APK 大小要一起改。

## 原则

- 没有登录界面：任何需要平台登录的功能都不做（评论只读、点赞只存本地）。
- 独立版不用 TMDB：元数据只用豆瓣（商店网站仍用 TMDB）。
- 直连优先：音视频流直接走 CDN，只有浏览器连不上的接口调用才走服务器中转。
- 播放解析：按速度串行问源，第一个能播的地址立刻播，不为等更高音质拖延；没有目标音质就立刻降一档播。
