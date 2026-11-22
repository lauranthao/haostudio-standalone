// Music transport controls, iOS-native (build 29 adoption) — Dart
// side is lib/widgets/native_music_transport.dart
// (`NativeMusicTransport`).
//
// Why SwiftUI instead of another Flutter row: chen wants the player
// control area to feel like an iOS-native app, and the transport
// cluster (prev / play-pause / next) is tap-only buttons — no drag
// ever starts on them, so a PlatformView here cannot eat any
// gesture. The progress Slider stays Flutter for exactly that
// reason (same three technical points as VodControlsPlugin).
//
// Layout (chen's screenshot, same as the Flutter fallback):
// three equal slots, no background circles — bare white triangles.
// Prev/next 25pt semibold, 58pt tall; play/pause 36pt bold, 64pt
// tall. SF Symbols match the Flutter icons: backward.fill /
// play.fill / pause.fill / forward.fill.
//
//  - One view per widget: the Dart widget id (creationParams `id`)
//    keys the registry — the engine's platform-view id is NOT used,
//    because Dart only knows its own id (same convention as
//    NativeSwitchPlugin / VodControlsPlugin).
//  - Single source of truth stays Flutter-side (the player's
//    `isPlaying`): Dart pushes `setState` when props change; the
//    native side only reports user taps as `onTap` {id, action} on
//    the events channel, and Dart echoes nothing back for its own
//    taps (the parent rebuild carries the same value, so
//    `didUpdateWidget` sees no diff).
//  - Best-effort throughout: a command for an unknown id (view not
//    created yet, or already disposed) is a silent no-op, never an
//    error — Dart may push before the view exists.
//  - The view paints no glass of its own (clear background, white
//    symbols): it reads the same at glass 0% and 100%, because the
//    gradient container behind it does the work.
//
// REGISTRATION (AppDelegate.swift — same block shape as
// VodControlsPlugin):
//   if let registrar = engineBridge.pluginRegistry.registrar(
//       forPlugin: "com.haostudio.standalone.MusicTransportPlugin") {
//     MusicTransportPlugin.register(with: registrar)
//   }
// ...and add this file to the Runner target in Xcode
// (ios/Runner.xcodeproj/project.pbxproj). Until both land, the page
// keeps `nativeMusicTransport: false` and the Flutter fallback
// renders — the plugin file alone changes nothing at runtime.
// NOT compiled on the VM (no Xcode here): Codemagic must build it
// before the flag flips.

import Flutter
import SwiftUI
import UIKit

/// Actions the native transport reports to Dart. Must match
/// lib/widgets/native_music_transport.dart (`MusicTransportAction`).
private enum MusicTransportAction: String {
    case prev
    case playPause
    case next
}

private final class MusicTransportModel: ObservableObject {
    @Published var playing: Bool

    init(playing: Bool) {
        self.playing = playing
    }
}

private struct MusicTransportView: View {
    @ObservedObject var model: MusicTransportModel
    let onTap: (MusicTransportAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onTap(.prev)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上一首")
            Button {
                onTap(.playPause)
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.playing ? "暂停" : "播放")
            Button {
                onTap(.next)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")
        }
    }
}

final class MusicTransportPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MusicTransportPlugin(messenger: registrar.messenger())
        let commandChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/music_transport",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: commandChannel)
        registrar.register(
            MusicTransportFactory(plugin: instance),
            withId: "com.haostudio.standalone/music_transport")
    }

    private let eventChannel: FlutterMethodChannel
    private var models: [Int64: MusicTransportModel] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.eventChannel = FlutterMethodChannel(
            name: "com.haostudio.standalone/music_transport/events",
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
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    fileprivate func registerModel(_ model: MusicTransportModel, id: Int64) {
        models[id] = model
    }

    fileprivate func unregisterModel(id: Int64) {
        models.removeValue(forKey: id)
    }

    fileprivate func controlTapped(id: Int64, action: MusicTransportAction) {
        eventChannel.invokeMethod(
            "onTap", arguments: ["id": id, "action": action.rawValue])
    }
}

final class MusicTransportFactory: NSObject, FlutterPlatformViewFactory {
    private weak var plugin: MusicTransportPlugin?

    init(plugin: MusicTransportPlugin) {
        self.plugin = plugin
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        MusicTransportViewWrapper(
            frame: frame, viewId: viewId, arguments: args, plugin: plugin)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class MusicTransportViewWrapper: NSObject, FlutterPlatformView {
    private let hostingController: UIHostingController<MusicTransportView>
    private let id: Int64
    private weak var plugin: MusicTransportPlugin?

    init(
        frame: CGRect,
        viewId: Int64,
        arguments args: Any?,
        plugin: MusicTransportPlugin?
    ) {
        self.plugin = plugin
        let dict = args as? [String: Any]
        // The Dart widget id arrives in creationParams; the engine's
        // viewId is only a fallback and is never used by Dart.
        self.id = (dict?["id"] as? NSNumber)?.int64Value ?? viewId
        let model = MusicTransportModel(
            playing: (dict?["playing"] as? NSNumber)?.boolValue ?? false)
        let pluginRef = plugin
        let viewIdCopy = self.id
        self.hostingController = UIHostingController(
            rootView: MusicTransportView(
                model: model,
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
