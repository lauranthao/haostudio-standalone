import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    // 120Hz lock (chen 2026-11-16: 锁定120hz): a display link pinned to
    // 120fps holds the ProMotion display at 120Hz instead of adapting
    // down. Info.plist CADisableMinimumFrameDurationOnPhone removes the
    // 60fps cap; this link requests the fixed 120Hz rate for the app's
    // lifetime. The tick is a no-op — the link exists only to hold the rate.
    private var hao120HzLink: CADisplayLink?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        haoLock120Hz()
        return true
    }

    private func haoLock120Hz() {
        let link = CADisplayLink(target: self, selector: #selector(hao120HzTick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        hao120HzLink = link
    }

    @objc private func hao120HzTick() {}

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
