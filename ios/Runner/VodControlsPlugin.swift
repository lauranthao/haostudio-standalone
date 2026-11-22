// VOD player controls, iOS-native (build 29, K group) — Dart side is
// lib/widgets/native_vod_controls.dart (`NativeVodControls`).
//
// Why SwiftUI instead of another Flutter row: chen wants the player
// control area to feel like an iOS-native app, and the transport
// cluster (prev / play-pause / next) plus the trailing cluster
// (rate + exit-fullscreen) are tap-only buttons — no drag ever
// starts on them, so a PlatformView here cannot eat the drag-seek
// gesture. The Slider and the line pills stay Flutter for exactly
// that reason (see the three technical points below).
//
// Three technical points (H group's assessment, resolved here):
//   (a) Gesture pass-through: NOT needed — only tap-only buttons
//       are native. Drag-seek lives on the Flutter Slider and the
//       surface drag handlers; no drag starts on a native view,
//       so nothing is swallowed. Do NOT move the Slider or the
//       line pills into this plugin.
//   (b) MethodChannel size negotiation: NOT needed — no
//       variable-length content lives in the native views. Both
//       clusters are fixed-width (transport 144x48, trailing
//       112x48); the rate label is bounded to 5 chars ("1.25x")
//       inside a fixed 56 px button. Line names stay Flutter.
//   (c) Flutter fallback: `NativeVodControls` renders the current
//       Flutter buttons verbatim when `nativeEnabled` is false
//       (the default) or off iOS — same icons, sizes, tooltips,
//       callbacks. The page flips one flag; nothing else changes.
//
//  - One factory, two clusters: creationParams `cluster` is
//    "transport" or "trailing". One view per widget: the Dart
//    widget id (creationParams `id`) keys the registry — the
//    engine's platform-view id is NOT used, because Dart only
//    knows its own id (same convention as NativeSwitchPlugin).
//  - Single source of truth stays Flutter-side (the page's
//    `_playing` / `_rateLabel`): Dart pushes `setState` when its
//    props change; the native side only reports user taps as
//    `onTap` {id, action} on the events channel, and Dart echoes
//    nothing back for its own taps (the parent rebuild carries
//    the same value, so `didUpdateWidget` sees no diff).
//  - Best-effort throughout: a command for an unknown id (view
//    not created yet, or already disposed) is a silent no-op,
//    never an error — Dart may push before the view exists.
//  - The view paints no glass of its own (clear background, white
//    symbols/text): it reads the same at glass 0% and 100%,
//    because the gradient container behind it does the work.
//
// REGISTRATION (G group — AppDelegate.swift is E group's right
// now, do NOT edit it from this change):
//   if let registrar = engineBridge.pluginRegistry.registrar(
//       forPlugin: "com.haostudio.standalone.VodControlsPlugin") {
//     VodControlsPlugin.register(with: registrar)
//   }
// ...and add this file to the Runner target in Xcode
// (ios/Runner.xcodeproj/project.pbxproj). Until both land, the
// page keeps `nativeVodControls: false` and the Flutter fallback
// renders — the plugin file alone changes nothing at runtime.
// NOT compiled on the VM (no Xcode here): G group must build it.

import Flutter
import SwiftUI
import UIKit

/// Actions the native clusters report to Dart. Must match
/// lib/widgets/native_vod_controls.dart (`VodControlAction`).
private enum VodControlAction: String {
    case prev
    case playPause
    case next
    case rate
    case exit
}

private final class VodControlsModel: ObservableObject {
    @Published var playing: Bool
    @Published var rateLabel: String

    init(playing: Bool, rateLabel: String) {
        self.playing = playing
        self.rateLabel = rateLabel
    }
}

private struct VodControlsView: View {
    @ObservedObject var model: VodControlsModel
    let cluster: String
    let onTap: (VodControlAction) -> Void

    var body: some View {
        if cluster == "trailing" {
            HStack(spacing: 8) {
                Button {
                    onTap(.rate)
                } label: {
                    Text(model.rateLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("倍速")
                Button {
                    onTap(.exit)
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退出全屏")
            }
            .frame(width: 112, height: 48)
        } else {
            HStack(spacing: 0) {
                Button {
                    onTap(.prev)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("上一集")
                Button {
                    onTap(.playPause)
                } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.playing ? "暂停" : "播放")
                Button {
                    onTap(.next)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一集")
            }
            .frame(width: 144, height: 48)
        }
    }
}

final class VodControlsPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VodControlsPlugin(messenger: registrar.messenger())
        let commandChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/vod_controls",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: commandChannel)
        registrar.registerViewFactory(
            VodControlsFactory(plugin: instance),
            withId: "com.haostudio.standalone/vod_controls")
    }

    private let eventChannel: FlutterMethodChannel
    private var models: [Int64: VodControlsModel] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.eventChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/vod_controls/events",
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
        guard let model = models[id] else {
            result(nil)
            return
        }
        switch call.method {
        case "setState":
            if let playing = (args["playing"] as? NSNumber)?.boolValue {
                model.playing = playing
            }
            if let rateLabel = args["rateLabel"] as? String {
                model.rateLabel = rateLabel
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    fileprivate func registerModel(_ model: VodControlsModel, id: Int64) {
        models[id] = model
    }

    fileprivate func unregisterModel(id: Int64) {
        models.removeValue(forKey: id)
    }

    fileprivate func controlTapped(id: Int64, action: VodControlAction) {
        eventChannel.invokeMethod(
            "onTap", arguments: ["id": id, "action": action.rawValue])
    }
}

final class VodControlsFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: VodControlsPlugin?

    init(plugin: VodControlsPlugin) {
        self.plugin = plugin
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        VodControlsViewWrapper(
            frame: frame, viewId: viewId, arguments: args, plugin: plugin)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class VodControlsViewWrapper: NSObject, FlutterPlatformView {
    private let hostingController: UIHostingController<VodControlsView>
    private let id: Int64
    private weak var plugin: VodControlsPlugin?

    init(
        frame: CGRect,
        viewId: Int64,
        arguments args: Any?,
        plugin: VodControlsPlugin?
    ) {
        self.plugin = plugin
        let dict = args as? [String: Any]
        // The Dart widget id arrives in creationParams; the engine's
        // viewId is only a fallback and is never used by Dart.
        self.id = (dict?["id"] as? NSNumber)?.int64Value ?? viewId
        let cluster = (dict?["cluster"] as? String) ?? "transport"
        let model = VodControlsModel(
            playing: (dict?["playing"] as? NSNumber)?.boolValue ?? false,
            rateLabel: (dict?["rateLabel"] as? String) ?? "1.0x")
        let pluginRef = plugin
        let viewIdCopy = self.id
        self.hostingController = UIHostingController(
            rootView: VodControlsView(
                model: model,
                cluster: cluster,
                onTap: { action in
                    pluginRef?.controlTapped(id: viewIdCopy, action: action)
                }))
        super.init()
        hostingController.view.backgroundColor = .clear
        hostingController.view.frame = frame
        plugin?.registerModel(model, id: id)
    }

    func view() -> UIView {
        hostingController.view
    }

    func dispose() {
        plugin?.unregisterModel(id: id)
    }
}
