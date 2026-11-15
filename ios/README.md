# HAo Studio 独立版 — iOS 工程（(e) 原生/Xcode 线）

零网站连接的独立 IPA：前端打进包内本地加载，不登录、无商店、无社区、无后台，
所有流量走手机直连（nativeFetch 桥）或 file:// 本地页面。

## 工程结构

| 路径 | 说明 |
|---|---|
| `HAoStudio/` | App target：`AppDelegate`、`SceneDelegate`、`ViewController`、`NativePlayerViewController`、`NativeMusicPlayer`、`LyricsLiveActivity`、`Assets.xcassets`、`Base.lproj/LaunchScreen.storyboard`、`Info.plist`、`HAoStudio.entitlements`（空）、`tmdb-config.json`、`web/`（前端快照） |
| `HAoStudioLyrics/` | 锁屏歌词 Live Activity 扩展（`com.haostudio.standalone.lyrics`） |
| `HAoStudioWidget/` | 小组件代码**仅存档，不在任何 target 内**（v1 不发版；以后要加再建 target，bundle id 须改 standalone 后缀） |
| `HAoStudio.xcodeproj/` | 工程文件（2 个 target：HAoStudio、HAoStudioLyrics） |
| `Podfile` | `IJKMediaFramework 0.1.5`（ijkplayer，影视/直播） |
| `patch_pbxproj.py` | 本工程从店铺版重组的手术脚本（审计用） |

## 关键约定

- **Bundle ID**：`com.haostudio.standalone`（与店铺版 `com.haostudio.shop` 区分，可双装）；显示名 `HAo Studio`；iOS 15.0；`UIBackgroundModes = audio`。
- **前端加载**：`WKWebView.loadFileURL(web/index.html, allowingReadAccessTo: web/)`，`web/` 是 `HAoStudio/web/` 的文件夹引用。`../web/`（(a) 线拥有）是唯一来源，构建时由 `codemagic.yaml` 同步进包；本地快照仅作后备。**集成注意**：店铺版前端用根绝对路径（`/app.js`、`/style.css`、`/music-cover.svg`），在 `file://` 下会解析到文件系统根目录而加载失败；(a) 线精简前端时必须改成相对路径（`./app.js` 等），否则包内页面白屏。
- **三桥保留**：`nativePlayer`（ijkplayer 直播/VOD）、`nativeFetch`（直连 API，54 hosts allowlist，见 `ViewController.swift`）、`nativeMusic`（AVPlayer 零停顿音乐）；`window.__HAO_NATIVE__` 注入保留；音频会话/后台恢复逻辑保留（`resumeWebMusicIfNeeded` + `NativeMusicPlayer`）。
- **TMDB key**：包内 `HAoStudio/tmdb-config.json`（默认 `{"tmdb_api_key":""}`），构建脚本从环境变量 `TMDB_API_KEY` 注入（见仓库根 `codemagic.yaml`）。JS 侧注入为 `window.__HAO_TMDB_KEY__`（atDocumentStart）。(a) 线接口：`window.HaoSources.getTmdbKey()` 优先读用户设置，其次读 `window.__HAO_TMDB_KEY__`，为空则跳过 TMDB enrichment。
- **弹幕端点**：VOD 外部弹幕默认无服务器。网页通过 `nativePlayer` 消息的 `dm.endpoint` 传用户配置的端点（`HaoSources.getDanmakuEndpoint()`，默认空）；未配置时 `DanmakuConfig.baseURL` 为 `https://localhost/` 占位，`fetchDanmaku` 直接跳过不请求。
- **删掉的**：`CarPlayManager.swift`（文件已删，v1 不做 CarPlay）、小组件 target（代码留档）、一切店铺/网站引用（shop URL、office-status、client-log、my-ip、登录 token 相关逻辑）。
- **NativePlayerViewController.swift**：(d) 线拥有，本工程暂用店铺版原样复制，仅把两处死代码里的店铺 URL 换成 `https://localhost/` 占位 + `fetchDanmaku` 加 localhost 跳过；(d) 的改版到了直接替换本文件。

## 构建

`codemagic.yaml` 在仓库根（`standalone-app/codemagic.yaml`），workflow `ios-unsigned`（mac_mini_m1，未签名 IPA）。Gitee 仓库由父级新建后，在 Codemagic 添加仓库并选该工作流；`TMDB_API_KEY` 在 Codemagic 网页端环境变量里设置。

## 预检（2026-11-16，(e) 线）

见汇报：Swift 5.0、文件引用、Asset、arm64、部署目标、Bundle ID、后台音频、音频会话逐项已查；`data(withJSONObject:` 代码调用为 0（唯一命中是注释里的旧崩溃说明，已改写，grep 为 0）。无 Mac，未做真实编译，编译通过不保证。
