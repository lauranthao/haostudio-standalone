# HAo Studio 独立版

零网站连接的独立 IPA：WKWebView 壳 + 打包进应用的本地前端。不登录、无商店、无社区、无后台，所有流量走手机直连。

## 构建

Codemagic，workflow `ios-unsigned`（branch master），产物 `ios/HAoStudio.ipa`。

- 前端唯一来源是 `web/`，构建时同步进 `ios/HAoStudio/web/`。
- `TMDB_API_KEY` 在 Codemagic 环境变量里设置，不进仓库（空 key 时 App 跳过 TMDB 补全）。

## 在线更新

App 读 `https://raw.githubusercontent.com/lauranthao/haostudio-standalone/master/version.json` 检查更新，提示后由用户在 Safari 下载 IPA、经 LCSign / TrollStore 安装（侧载应用无法静默安装）。
