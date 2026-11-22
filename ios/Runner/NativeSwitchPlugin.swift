// Native iOS switch bridge (build 29, E group) — Dart side is
// lib/widgets/native_switch.dart (`HaoNativeSwitch`, the app's only
// switch component).
//
// Why a real UISwitch instead of another Flutter switch: chen's
// screenshot (音源管理) showed the four platform rows as solid black
// ovals — the Material `SwitchListTile` was given
// `activeThumbColor: theme.accent`, and the default appleGlass light
// accent is pure black (0xFF000000), while the theme's selected
// track is the same accent, so thumb == track == black and the knob
// vanishes. A Flutter re-skin could paint a white knob, but chen
// (2026-11-22, second confirmation) wants the iOS native control,
// so this is the real `UISwitch` hosted in a `UiKitView`.
//
//  - One view per widget: the Dart widget id (creationParams `id`)
//    keys the registry — the engine's platform-view id is NOT used,
//    because Dart only knows its own id.
//  - Single source of truth stays Flutter-side (the Hive-backed
//    store the caller already reads): the native switch is a view
//    of `value`. Dart pushes `setValue` / `setOnTintColor` /
//    `setEnabled` when its props change; the native side only
//    reports user flips as `onChanged` on the events channel, and
//    Dart echoes nothing back for its own flips (the parent rebuild
//    carries the same value, so `didUpdateWidget` sees no diff).
//  - The thumb is pinned white (`thumbTintColor = .white`):
//    whatever accent the user picks, the knob can never again be
//    the same colour as the track. The OFF track is iOS's own
//    system grey — visible in light and dark, at glass 0% and 100%,
//    because the switch paints no glass of its own.
//  - Best-effort throughout: a command for an unknown id (view not
//    created yet, or already disposed) is a silent no-op, never an
//    error — Dart may push before the view exists.

import Flutter
import UIKit

final class NativeSwitchPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NativeSwitchPlugin(messenger: registrar.messenger())
        let commandChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/native_switch",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: commandChannel)
        registrar.register(
            NativeSwitchFactory(plugin: instance),
            withId: "com.haostudio.standalone/native_switch")
    }

    private let eventChannel: FlutterMethodChannel
    private var switches: [Int64: UISwitch] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.eventChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/native_switch/events",
            binaryMessenger: messenger)
        super.init()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = (args["id"] as? NSNumber)?.int64Value
        else {
            result(FlutterError(
                code: "bad_args",
                message: "\(call.method) needs an id",
                details: nil))
            return
        }
        // Unknown id: the view is not created yet or already
        // disposed — Dart pushes are best-effort, so swallow it.
        guard let uiSwitch = switches[id] else {
            result(nil)
            return
        }
        switch call.method {
        case "setValue":
            // StandardMessageCodec delivers Dart bools as NSNumber —
            // read boolValue (same pattern as SystemVolumePlugin),
            // never `as? Bool`.
            guard let value = (args["value"] as? NSNumber)?.boolValue else {
                result(FlutterError(
                    code: "bad_args",
                    message: "setValue needs a value bool",
                    details: nil))
                return
            }
            let animated = (args["animated"] as? NSNumber)?.boolValue ?? false
            uiSwitch.setOn(value, animated: animated)
            result(nil)
        case "setOnTintColor":
            guard let argb = (args["color"] as? NSNumber)?.intValue else {
                result(FlutterError(
                    code: "bad_args",
                    message: "setOnTintColor needs a color int",
                    details: nil))
                return
            }
            uiSwitch.onTintColor = UIColor(haoARGB: argb)
            result(nil)
        case "setEnabled":
            guard let enabled = (args["enabled"] as? NSNumber)?.boolValue else {
                result(FlutterError(
                    code: "bad_args",
                    message: "setEnabled needs an enabled bool",
                    details: nil))
                return
            }
            uiSwitch.isEnabled = enabled
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    fileprivate func registerSwitch(_ uiSwitch: UISwitch, id: Int64) {
        switches[id] = uiSwitch
    }

    fileprivate func unregisterSwitch(id: Int64) {
        switches.removeValue(forKey: id)
    }

    fileprivate func switchDidChange(id: Int64, value: Bool) {
        eventChannel.invokeMethod(
            "onChanged", arguments: ["id": id, "value": value])
    }
}

final class NativeSwitchFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: NativeSwitchPlugin?

    init(plugin: NativeSwitchPlugin) {
        self.plugin = plugin
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        NativeSwitchView(
            frame: frame, viewId: viewId, arguments: args, plugin: plugin)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class NativeSwitchView: NSObject, FlutterPlatformView {
    private let uiSwitch: UISwitch
    private let id: Int64
    private weak var plugin: NativeSwitchPlugin?

    init(
        frame: CGRect,
        viewId: Int64,
        arguments args: Any?,
        plugin: NativeSwitchPlugin?
    ) {
        self.plugin = plugin
        let dict = args as? [String: Any]
        // The Dart widget id arrives in creationParams; the engine's
        // viewId is only a fallback and is never used by Dart.
        self.id = (dict?["id"] as? NSNumber)?.int64Value ?? viewId
        self.uiSwitch = UISwitch(frame: frame)
        super.init()
        uiSwitch.isOn = (dict?["value"] as? NSNumber)?.boolValue ?? false
        if let argb = (dict?["onTintColor"] as? NSNumber)?.intValue {
            uiSwitch.onTintColor = UIColor(haoARGB: argb)
        }
        // The thumb must stay white whatever the accent is — the
        // black-block bug was thumb == track == accent.
        uiSwitch.thumbTintColor = .white
        uiSwitch.isEnabled = (dict?["enabled"] as? NSNumber)?.boolValue ?? true
        uiSwitch.backgroundColor = .clear
        if let label = dict?["semanticsLabel"] as? String, !label.isEmpty {
            uiSwitch.accessibilityLabel = label
        }
        uiSwitch.addTarget(
            self, action: #selector(switchChanged), for: .valueChanged)
        plugin?.registerSwitch(uiSwitch, id: id)
    }

    func view() -> UIView {
        uiSwitch
    }

    func dispose() {
        uiSwitch.removeTarget(
            self, action: #selector(switchChanged), for: .valueChanged)
        plugin?.unregisterSwitch(id: id)
    }

    @objc private func switchChanged() {
        plugin?.switchDidChange(id: id, value: uiSwitch.isOn)
    }
}

private extension UIColor {
    /// ARGB int as produced by Dart `Color.toARGB32()` (0xAARRGGBB).
    convenience init(haoARGB argb: Int) {
        let a = CGFloat((argb >> 24) & 0xFF) / 255
        let r = CGFloat((argb >> 16) & 0xFF) / 255
        let g = CGFloat((argb >> 8) & 0xFF) / 255
        let b = CGFloat(argb & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
