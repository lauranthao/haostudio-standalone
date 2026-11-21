// Person segmentation bridge (1.1.6, danmaku occlusion avoidance,
// reduced version) — Dart side of the Vision person-segmentation
// plugin.
//
//  - Dart sends one low-frequency MPV snapshot (JPEG) over the
//    `com.haostudio.standalone/person_segmentation` MethodChannel
//    (`segmentFrame`).
//  - This side runs `VNGeneratePersonSegmentationRequest` (iOS 15+,
//    single mask for all people — matches the deployment target
//    15.0, no version bump; the per-person mask API needs iOS 17+
//    and is NOT used) at `.fast` quality (256x144 output) and
//    returns the single-channel mask bytes + frame size + a
//    hasPerson flag + the current thermal state.
//  - No extra permission: the frame is pixels the app is already
//    playing, in-process; no camera, no photo library, no network,
//    no model download (Vision ships the model with iOS), no
//    `.mlmodel` / `.mlpackage` in the bundle.
//  - Best-effort throughout: any failure returns nil and Dart
//    treats it as "skip this frame, keep the old mask" — the film
//    never stops for a decoration.
//  - Calls are serialized: a second `segmentFrame` while one is in
//    flight is dropped (nil) instead of queueing — Dart's loop never
//    overlaps ticks anyway, and a stale mask must never queue up
//    behind a fresh one.

import Flutter
import UIKit
import Vision

final class PersonSegmentationPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.haostudio.standalone/person_segmentation",
            binaryMessenger: registrar.messenger())
        let instance = PersonSegmentationPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private let channel: FlutterMethodChannel
    // One reused request: VNRequest instances are reusable across
    // perform calls, but NOT concurrently — the `busy` flag below
    // serializes them. A fresh VNImageRequestHandler is built per
    // frame (cheap, stateless); VNSequenceRequestHandler is NOT used
    // — it needs a CVPixelBuffer input (an extra CGImage conversion)
    //    and its temporal state is of dubious value across the 1 Hz
    // patrol gaps.
    private let request: VNGeneratePersonSegmentationRequest
    private var busy = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.request = request
        super.init()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "segmentFrame" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let args = call.arguments as? [String: Any],
              let jpeg = args["jpeg"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "bad_args", message: "segmentFrame needs {jpeg: Uint8List}", details: nil))
            return
        }
        // Drop instead of queue: a mask that arrives late is worse
        // than no mask (the Dart loop skips the frame and keeps the
        // previous mask).
        guard !busy else {
            result(nil)
            return
        }
        busy = true
        let jpegData = jpeg.data
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            self.segment(jpegData: jpegData, result: result)
        }
    }

    private func segment(jpegData: Data, result: @escaping FlutterResult) {
        // Finish on main: clears `busy` and delivers the result on
        // the thread the channel expects.
        func finish(_ value: Any?) {
            DispatchQueue.main.async { [weak self] in
                self?.busy = false
                result(value)
            }
        }
        guard let image = UIImage(data: jpegData),
              let cgImage = image.cgImage else {
            finish(nil)
            return
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            finish(nil)
            return
        }
        guard let observation = request.results?.first,
              let pixelBuffer = Optional(observation.pixelBuffer) else {
            finish(nil)
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            finish(nil)
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // Copy row by row: bytesPerRow may exceed width (stride
        // padding), so a single bulk copy would smear rows.
        var mask = Data(capacity: width * height)
        let row = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            mask.append(row.advanced(by: y * bytesPerRow), count: width)
        }
        // hasPerson: any real person, not a stray noisy pixel.
        // Threshold ~0.1% of a 256x144 mask (~37 px).
        var personPixels = 0
        for byte in mask where byte > 127 {
            personPixels += 1
        }
        let hasPerson = personPixels > 36
        finish([
            "mask": FlutterStandardTypedData(bytes: mask),
            "width": width,
            "height": height,
            "frameWidth": cgImage.width,
            "frameHeight": cgImage.height,
            "hasPerson": hasPerson,
            // ProcessInfo.ThermalState raw values: 0 nominal,
            // 1 fair, 2 serious, 3 critical. Dart degrades on
            // fair (1 Hz) and stops on serious/critical.
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ] as [String: Any])
    }
}
