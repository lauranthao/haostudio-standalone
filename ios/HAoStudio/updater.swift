// updater.swift
// HAo Studio 独立版 — 应用内更新检查（工作流 f）
// 独立文件，直接并入 (e) 线的 Xcode 工程即可使用，无需改其他文件。
//
// 原则：
// - App 只联系一个地址：GitHub 仓库直链上的 version.json（见 versionJSONURLString）。
//   除此之外 App 不联系任何服务器（见 UPDATE_SPEC.md 隐私说明）。
//   注：用 raw.githubusercontent.com 直链；URLSession 直接取 200，无需跟随跳转。
// - 绝不静默安装：iOS 侧载应用无法静默安装另一个 IPA。只能提示用户，
//   由用户点「下载」在 Safari 里下载 IPA，再用 LCSign / TrollStore 手动安装。
// - 检查失败（无网、超时、JSON 损坏）一律静默，不打扰用户。

import UIKit

public enum HaoUpdater {

    // MARK: - 配置

    /// version.json 的地址。(e) 接入时如仓库名变化，只改这一处。
    /// GitHub raw 直链格式：https://raw.githubusercontent.com/<用户名>/<仓库名>/<分支>/version.json
    public static var versionJSONURLString =
        "https://raw.githubusercontent.com/lauranthao/haostudio-standalone/master/version.json"

    /// 单次请求超时（秒）。超过即静默失败。
    public static var requestTimeout: TimeInterval = 10

    /// 自动检查间隔：每天最多一次。
    public static var autoCheckInterval: TimeInterval = 24 * 60 * 60

    private static let lastAutoCheckKey = "hao_sa_updater_last_auto_check"
    private static var isPromptShowing = false

    // MARK: - 数据模型（对应 version.json）

    public struct VersionInfo: Codable {
        public let version: String          // 如 "1.0.1"
        public let build: Int               // 如 2
        public let changelog: [String: String]  // "zh" / "tw" / "en"
        public let ipaUrl: String           // 新版 IPA 直链（GitHub raw）
        public let minOs: String            // 如 "15.0"
        public let size: Int                // IPA 字节数，0 = 未知

        /// 按当前系统语言取 changelog，依次回退：首选语言 → zh → en → 任意一条。
        public var localizedChangelog: String {
            let preferred = HaoUpdater.preferredChangelogLanguage
            if let text = changelog[preferred], !text.isEmpty { return text }
            if let text = changelog["zh"], !text.isEmpty { return text }
            if let text = changelog["en"], !text.isEmpty { return text }
            return changelog.values.first ?? ""
        }

        /// 当前设备系统版本是否满足 minOs。
        public var isCompatibleWithDevice: Bool {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let device = [os.majorVersion, os.minorVersion, os.patchVersion]
            let required = minOs.split(separator: ".").compactMap { Int($0) }
            for i in 0..<max(device.count, required.count) {
                let d = i < device.count ? device[i] : 0
                let r = i < required.count ? required[i] : 0
                if d != r { return d > r }
            }
            return true
        }
    }

    // MARK: - 对外入口

    /// 启动后调用：3 秒后做一次自动检查（每天最多一次，失败静默）。
    /// (e) 在 App 启动完成处调用一次即可。
    public static func scheduleLaunchCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            check(force: false)
        }
    }

    /// 手动检查：设置页「检查更新」按钮调用。
    /// - force: true 时忽略每天一次的限制；无新版时弹「已是最新版本」。
    public static func checkManually(from viewController: UIViewController? = nil) {
        check(force: true, presentingViewController: viewController)
    }

    /// 核心检查。
    /// - force: false = 自动检查（受每天一次限制，失败/无新版全程静默）；
    ///   true = 手动检查（无新版时也给用户一个明确反馈）。
    /// - completion: 仅在发现新版时回传 VersionInfo；其余情况回传 nil。
    public static func check(
        force: Bool = false,
        presentingViewController: UIViewController? = nil,
        completion: ((VersionInfo?) -> Void)? = nil
    ) {
        if !force, !shouldAutoCheck() {
            completion?(nil)
            return
        }
        guard let url = URL(string: versionJSONURLString) else {
            completion?(nil)  // 地址配错也静默，不打扰用户
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: url) { data, _, _ in
            // 无论成功失败，自动检查都记一次时间（每天最多一次）。
            if !force {
                UserDefaults.standard.set(Date(), forKey: lastAutoCheckKey)
            }
            guard let data = data,
                  let info = try? JSONDecoder().decode(VersionInfo.self, from: data),
                  isNewer(info.version, than: currentVersion()) else {
                // 无网 / 超时 / JSON 损坏 / 无新版：全部静默。
                // 手动检查时给用户一个「已是最新版本」的反馈。
                if force {
                    DispatchQueue.main.async {
                        showUpToDateAlert(from: presentingViewController)
                    }
                }
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            DispatchQueue.main.async {
                completion?(info)
                prompt(info: info, from: presentingViewController)
            }
        }
        task.resume()
    }

    /// 有新版时弹系统提示：标题 + 三语 changelog +「下载」/「稍后」。
    /// 点「下载」用 Safari 打开 ipaUrl，用户下载后自行用 LCSign / TrollStore 安装。
    public static func prompt(info: VersionInfo, from viewController: UIViewController? = nil) {
        guard !isPromptShowing else { return }
        guard let presenter = viewController ?? topViewController() else { return }
        isPromptShowing = true

        var message = info.localizedChangelog
        if info.size > 0 {
            message += "\n\n大小：约 \(formattedSize(info.size))"
        }
        if !info.isCompatibleWithDevice {
            message += "\n\n注意：此版本需要 iOS \(info.minOs) 或以上，当前设备系统版本较低。"
        }

        let alert = UIAlertController(
            title: "发现新版本 \(info.version)",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "下载", style: .default) { _ in
            isPromptShowing = false
            if let ipaURL = URL(string: info.ipaUrl) {
                UIApplication.shared.open(ipaURL, options: [:], completionHandler: nil)
            }
        })
        alert.addAction(UIAlertAction(title: "稍后", style: .cancel) { _ in
            isPromptShowing = false
        })
        presenter.present(alert, animated: true, completion: nil)
    }

    // MARK: - 内部工具

    /// 今天是否还可以做自动检查（每天最多一次）。
    private static func shouldAutoCheck() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastAutoCheckKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= autoCheckInterval
    }

    /// 当前 App 版本（CFBundleShortVersionString）。
    private static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 语义化版本号比较："1.0.10" > "1.0.9"（按数字段比较，不是字符串比较）。
    private static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    /// 系统首选语言 → changelog 键："zh"（简体）/ "tw"（繁体）/ "en"。
    private static var preferredChangelogLanguage: String {
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.contains("Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
            return "tw"
        }
        if lang.hasPrefix("zh") { return "zh" }
        return "en"
    }

    private static func formattedSize(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
        }
        return "\(bytes / 1024) KB"
    }

    /// 手动检查且无新版时的反馈（自动检查不弹）。
    private static func showUpToDateAlert(from viewController: UIViewController? = nil) {
        guard let presenter = viewController ?? topViewController() else { return }
        let alert = UIAlertController(
            title: "已是最新版本",
            message: "当前版本 \(currentVersion()) 已是最新。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好的", style: .default, handler: nil))
        presenter.present(alert, animated: true, completion: nil)
    }

    /// 取最顶层 ViewController 用于弹提示（iOS 15 可用）。
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
