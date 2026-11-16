import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Now Playing shell for music (Fix 14): publishes the current
    // track to MPNowPlayingInfoCenter and forwards Lock Screen /
    // Control Center / Dynamic Island remote commands to Dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "com.haostudio.standalone.NowPlayingPlugin") {
      NowPlayingPlugin.register(with: registrar)
    }
  }
}
