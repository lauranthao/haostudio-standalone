import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // 120Hz lock (chen 2026-11-16: 锁定120hz): a display link pinned to
  // 120fps holds the ProMotion display at 120Hz instead of adapting
  // down. Info.plist CADisableMinimumFrameDurationOnPhone removes the
  // 60fps cap; this link requests the fixed 120Hz rate for the app's
  // lifetime. The tick is a no-op — the link exists only to hold the rate.
  // (Same mechanism as the Swift standalone app; the Flutter engine's
  // own display link alone was not holding 120Hz on chen's iPhone Air.)
  private var hao120HzLink: CADisplayLink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    haoLock120Hz()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Now Playing shell for music (Fix 14): publishes the current
    // track to MPNowPlayingInfoCenter and forwards Lock Screen /
    // Control Center / Dynamic Island remote commands to Dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "com.haostudio.standalone.NowPlayingPlugin") {
      NowPlayingPlugin.register(with: registrar)
    }
    // System volume (video / live drag volume drives the device
    // volume, not the player gain): getVolume / setVolume +
    // volumeChanged push for hardware keys / Control Center.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "com.haostudio.standalone.SystemVolumePlugin") {
      SystemVolumePlugin.register(with: registrar)
    }
    // Person segmentation (1.1.6, danmaku occlusion avoidance,
    // reduced version): Vision VNGeneratePersonSegmentationRequest
    // (iOS 15+, .fast) over low-frequency MPV snapshots; the mask
    // comes back to Dart for a whole-layer ShaderMask on the
    // danmaku layer. MPV-only, default off.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "com.haostudio.standalone.PersonSegmentationPlugin") {
      PersonSegmentationPlugin.register(with: registrar)
    }
  }
}
