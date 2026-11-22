// Notification haptics, iOS-native (build 29 adoption) — Dart side is
// lib/core/theme/haptics.dart (`HaoHaptics`).
//
// Flutter's HapticFeedback has no notification API, so success /
// warning / error were approximated with heavy/medium impact. iOS has
// UINotificationFeedbackGenerator for exactly these three signals,
// and Beans (the design reference, Components.swift) uses it too.
// This plugin exposes one method, `notification`
// {type: success|warning|error}, over the channel
// `com.haostudio.standalone/haptics`; Dart falls back to the old
// impact call when the channel is missing (unit tests, non-iOS), so
// the plugin file alone changes nothing until Codemagic builds it.
//
// REGISTRATION (AppDelegate.swift — same block shape as
// VodControlsPlugin / MusicTransportPlugin):
//   if let registrar = engineBridge.pluginRegistry.registrar(
//       forPlugin: "com.haostudio.standalone.HaoHapticsPlugin") {
//     HaoHapticsPlugin.register(with: registrar)
//   }
// ...and add this file to the Runner target in Xcode
// (ios/Runner.xcodeproj/project.pbxproj).
// NOT compiled on the VM (no Xcode here): Codemagic must build it
// before the Dart side can ever take the native path.

import Flutter
import UIKit

final class HaoHapticsPlugin: NSObject, FlutterPlugin {
  private static let generator = UINotificationFeedbackGenerator()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.haostudio.standalone/haptics",
      binaryMessenger: registrar.messenger())
    let instance = HaoHapticsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "notification" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let type = args["type"] as? String
    else {
      result(
        FlutterError(
          code: "BAD_ARGS",
          message: "notification needs {type}",
          details: nil))
      return
    }
    let feedback: UINotificationFeedbackGenerator.FeedbackType?
    switch type {
    case "success": feedback = .success
    case "warning": feedback = .warning
    case "error": feedback = .error
    default: feedback = nil
    }
    guard let feedback else {
      result(
        FlutterError(
          code: "BAD_TYPE",
          message: "unknown notification type: \(type)",
          details: nil))
      return
    }
    Self.generator.prepare()
    Self.generator.notificationOccurred(feedback)
    result(nil)
  }
}
