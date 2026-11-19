import AVFoundation
import Flutter
import MediaPlayer
import UIKit

// System volume shell — Dart side is lib/core/native/system_volume.dart
// (`com.haostudio.standalone/system_volume` MethodChannel).
//
// The video / live vertical-drag volume drives the DEVICE volume, not
// the player gain: the player gain (PlaybackSession.setVolume) leaves
// the system volume bar untouched, which is the bug chen reported
// ("调音量系统都不会变").
//
//  - Read: AVAudioSession.outputVolume.
//  - Write: the MPVolumeView slider — the only public way to change
//    the system volume on iOS. The view is parked off-screen
//    (-100,-100, 1×1, no route button) and never appears on screen;
//    the in-app drag HUD shows the value, so no system HUD is needed.
//  - Push: KVO on AVAudioSession.outputVolume forwards hardware-key /
//    Control Center changes to Dart as `volumeChanged`, so the drag
//    HUD stays on the real value.
//
// This plugin owns the hidden MPVolumeView. NowPlayingPlugin
// deliberately has none (its MPVolumeView was deleted per chen
// 2026-11-17); volume lives here only, one owner, no second slider.
final class SystemVolumePlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private var volumeView: MPVolumeView?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        AVAudioSession.sharedInstance().addObserver(
            self, forKeyPath: "outputVolume",
            options: [.new], context: nil)
    }

    deinit {
        AVAudioSession.sharedInstance().removeObserver(
            self, forKeyPath: "outputVolume")
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.haostudio.standalone/system_volume",
            binaryMessenger: registrar.messenger())
        let instance = SystemVolumePlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getVolume":
            result(AVAudioSession.sharedInstance().outputVolume)
        case "setVolume":
            guard let args = call.arguments as? [String: Any],
                  let volume = (args["volume"] as? NSNumber)?.doubleValue
            else {
                result(FlutterError(
                    code: "bad_args",
                    message: "setVolume needs a volume number",
                    details: nil))
                return
            }
            setSystemVolume(volume)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - System volume

    private func setSystemVolume(_ volume: Double) {
        guard let slider = volumeSlider() else { return }
        slider.setValue(Float(min(1.0, max(0.0, volume))), animated: false)
    }

    /// The MPVolumeView's internal slider. Created once, parked
    /// off-screen in the key window for the app's lifetime: the
    /// slider only drives the system volume while it is in a window
    /// hierarchy, and it must never be visible (same off-screen
    /// pattern as NowPlayingPlugin's route picker view).
    private func volumeSlider() -> UISlider? {
        if let view = volumeView {
            return view.subviews.first { $0 is UISlider } as? UISlider
        }
        guard let window = Self.keyWindow else { return nil }
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        view.showsRouteButton = false
        window.addSubview(view)
        view.layoutIfNeeded()
        volumeView = view
        return view.subviews.first { $0 is UISlider } as? UISlider
    }

    /// KVO fires on the thread that changed the volume; hop to main
    /// before invoking the channel (same rule as any UIKit work).
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "outputVolume" else { return }
        let volume = AVAudioSession.sharedInstance().outputVolume
        DispatchQueue.main.async { [weak self] in
            self?.channel.invokeMethod(
                "volumeChanged", arguments: ["volume": volume])
        }
    }

    /// iOS 13+ scene-based key-window lookup (`keyWindow` is
    /// deprecated). Same as NowPlayingPlugin.keyWindow.
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
