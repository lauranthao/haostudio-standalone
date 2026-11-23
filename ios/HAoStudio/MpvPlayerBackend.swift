// MpvPlayerBackend — libmpv (Predidit 0.6.8, mpv 0.36 core) behind the
// PlayerBackend protocol. This is Pure Live's default engine ('mpv' in
// player_consts.dart), via the same libmpv the media_kit fork in
// third_party/media_kit bundles (native_bundles.json ios_arm64:
// Predidit/libmpv-darwin-build 0.6.8, sha256-verified at build time).
//
// Rendering: the mpv *software* render API (MPV_RENDER_API_TYPE_SW,
// the same path media_kit's TextureSW uses as its fallback), rendering
// frames into a triple CVPixelBuffer pool and displaying them through
// an AVSampleBufferDisplayLayer. No OpenGL ES: EAGL is deprecated and
// the SW path is the only render path that needs no GL context at all.
// Cost: the CPU does the colorspace conversion + scaling, so this
// engine uses more CPU than ijkplayer's VideoToolbox decode on 1080p
// (a modern iPhone handles it; the user can switch to IJK in Settings
// if the phone runs warm). Hardware decode (hwdec=auto-safe) still
// applies — mpv downloads the VideoToolbox frames to CPU for the SW
// renderer, which is the documented hwdec + sw-render behaviour.
// Audio: mpv's audiounit output on the app's .playback audio session —
// background audio works like the other engines (the render work pauses
// in the background; the audio keeps playing).
//
// Tuning mirrors Pure Live's MpvEngineConfig.liveProperties
// (mpv_options.dart): 1 MiB probe / 1 s analyze, 6 s memory-only cache,
// 32 MiB demuxer cap, 15 s network timeout, hwdec software fallback.

import UIKit
import AVFoundation
import Mpv

// Container whose layer IS the display layer (videoGravity .resizeAspect,
// sized by the player to its videoView bounds on every layout pass).
private final class MpvVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

final class MpvPlayerBackend: NSObject, PlayerBackend {
    var onEvent: ((PlayerBackendEvent) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    private let containerView = MpvVideoView()
    private var rate: Double = 1

    private var mpvHandle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var isShutdown = false
    private var didEmitFirstFrame = false
    private var didEmitPrepared = false
    private var isBackgrounded = false

    // Serial queues: the mpv event loop (mpv_wait_event) and the render
    // work (render + display-layer enqueue) never overlap each other.
    private let eventQueue = DispatchQueue(label: "studio.hao.mpv-event", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "studio.hao.mpv-render", qos: .userInitiated)

    // Video size in pixels (dwidth/dheight), capped for the SW renderer.
    private var videoSize = CGSize.zero
    // Triple pixel-buffer pool (media_kit TextureSW pattern).
    private var pixelBuffers: [CVPixelBuffer] = []
    private var poolSize = CGSize.zero
    private var poolIndex = 0
    private var formatDescription: CMVideoFormatDescription?

    override init() {
        super.init()
        containerView.backgroundColor = .black
        containerView.displayLayer?.videoGravity = .resizeAspect
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func setVideoFit(_ fit: PlayerVideoFit) {
        switch fit {
        case .aspectFit: containerView.displayLayer?.videoGravity = .resizeAspect
        case .aspectFill: containerView.displayLayer?.videoGravity = .resizeAspectFill
        case .fill: containerView.displayLayer?.videoGravity = .resize
        }
    }

    var view: UIView { containerView }

    var isPlaying: Bool {
        guard let handle = mpvHandle else { return false }
        var paused: Int32 = 0
        guard mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused) >= 0 else { return false }
        return paused == 0
    }

    var currentTime: Double {
        guard let handle = mpvHandle else { return 0 }
        var t: Double = 0
        guard mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &t) >= 0, t.isFinite, t >= 0 else { return 0 }
        return t
    }

    var duration: Double {
        guard let handle = mpvHandle else { return Double.nan }
        var d: Double = 0
        guard mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &d) >= 0 else { return Double.nan }
        // Live streams report inf / -1: the player treats non-finite
        // as "unknown" (same guard it uses for the other engines).
        return d.isFinite ? d : Double.nan
    }

    var isPrepared: Bool {
        guard let handle = mpvHandle else { return false }
        // mpv has no single "prepared" flag; a file is loaded when the
        // core is not idle. FILE_LOADED also drives .prepared.
        var idle: Int32 = 0
        guard mpv_get_property(handle, "core-idle", MPV_FORMAT_FLAG, &idle) >= 0 else { return false }
        return idle == 0
    }

    var playbackRate: Double {
        get { rate }
        set {
            rate = newValue
            if let handle = mpvHandle {
                mpv_set_property_string(handle, "speed", String(newValue))
            }
        }
    }

    // MARK: - Open / play / pause / seek / shutdown

    @discardableResult
    func open(url: URL, headers: [String: String], isLive: Bool, format: String) -> Bool {
        shutdown()
        isShutdown = false
        didEmitFirstFrame = false
        didEmitPrepared = false
        videoSize = .zero
        guard let handle = mpv_create() else { return false }
        mpvHandle = handle
        // Options must be set BEFORE mpv_initialize (Pure Live's
        // MpvEngineConfig.liveProperties + the shared UA/Referer).
        setOption(handle, "config", "no")
        setOption(handle, "terminal", "no")
        setOption(handle, "vo", "libmpv")
        setOption(handle, "hwdec", "auto-safe")
        setOption(handle, "hwdec-software-fallback", "1")
        setOption(handle, "ao", "audiounit")
        setOption(handle, "force-seekable", "yes")
        setOption(handle, "protocol-whitelist", "httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt")
        setOption(handle, "demuxer-lavf-probesize", "1048576")
        setOption(handle, "demuxer-lavf-analyzeduration", "1")
        // Huya HLS segments carry a query string (xxx.ts?EXTINF=2.7);
        // FFmpeg's HLS demuxer blocks them without this (same fix as
        // the ijk allowed_extensions=ALL).
        setOption(handle, "demuxer-lavf-allowed-extensions", "ALL")
        setOption(handle, "cache", "yes")
        setOption(handle, "cache-on-disk", "no")
        setOption(handle, "cache-secs", "6")
        setOption(handle, "demuxer-max-bytes", "33554432")
        setOption(handle, "demuxer-max-back-bytes", "4194304")
        setOption(handle, "demuxer-donate-buffer", "no")
        setOption(handle, "demuxer-readahead-secs", "2")
        setOption(handle, "network-timeout", "15")
        // Pure Live 3.x MediaKitLiveProperties.sourceProperties,
        // applied per source in beforeOpen: a live stream (progressive
        // FLV or an HLS playlist) is NOT seekable and must NOT
        // cache-pause. mpv's cache-pause defaults to yes, which makes
        // a live stream play ~2s, then pause to buffer, then resume
        // ("plays then pauses then loads") — Pure Live 3.x fixed
        // exactly this by setting cache-pause=no for live. VOD keeps
        // the base force-seekable=yes and the default cache-pause.
        if isLive {
            setOption(handle, "cache-pause", "no")
            setOption(handle, "force-seekable", "no")
            if format == "hls" {
                setOption(handle, "demuxer-lavf-format", "hls")
            }
        }
        if let ua = headers["User-Agent"] { setOption(handle, "user-agent", ua) }
        if let referer = headers["Referer"] { setOption(handle, "http-header-fields", "Referer: \(referer)") }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
            return false
        }
        // Render context BEFORE loadfile: with vo=libmpv the VO needs
        // its render context when the file opens.
        guard createRenderContext(handle) else {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
            return false
        }
        // Properties the event loop watches (ids double as the
        // reply_userdata so the handler knows which one changed).
        mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 4, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 5, "dheight", MPV_FORMAT_INT64)
        startEventLoop()
        runCommand(["loadfile", url.absoluteString, "replace"])
        return true
    }

    func play() {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "no")
        // Keep the chosen speed: mpv resets speed to 1 on some seeks.
        mpv_set_property_string(handle, "speed", String(rate))
    }

    func pause() {
        guard let handle = mpvHandle else { return }
        mpv_set_property_string(handle, "pause", "yes")
    }

    func seek(to seconds: Double) {
        guard let handle = mpvHandle else { return }
        // Drop stale frames queued in the display layer.
        containerView.displayLayer?.flush()
        runCommand(["seek", String(seconds), "absolute"])
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        // Render context first (it must be freed before the core),
        // then the core. terminate_destroy wakes the event loop's
        // mpv_wait_event so the loop thread exits on its own.
        if let ctx = renderContext {
            mpv_render_context_set_update_callback(ctx, nil, nil)
            // Drain the render queue before freeing the context: a
            // render already in flight on renderQueue holds `ctx`
            // and would use it after free (use-after-free crash on
            // room switch / close / engine rebuild). renderQueue is
            // serial and never blocks on the caller, and shutdown is
            // never called from renderQueue, so this sync drain
            // cannot deadlock.
            renderQueue.sync {}
            mpv_render_context_free(ctx)
            renderContext = nil
        }
        if let handle = mpvHandle {
            mpvHandle = nil
            mpv_terminate_destroy(handle)
        }
        pixelBuffers.removeAll()
        formatDescription = nil
        poolSize = .zero
        DispatchQueue.main.async { [weak self] in
            self?.containerView.displayLayer?.flush()
        }
    }

    deinit {
        shutdown()
    }

    // MARK: - mpv helpers

    private func setOption(_ handle: OpaquePointer, _ name: String, _ value: String) {
        mpv_set_option_string(handle, name, value)
    }

    private func runCommand(_ args: [String]) {
        guard let handle = mpvHandle else { return }
        // Keep the mutable pointers to free them; pass the const
        // view to mpv (its args are `const char **`).
        let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { owned.forEach { if let p = $0 { free(p) } } }
        var cStrings: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
        cStrings.append(nil)
        cStrings.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command_async(handle, 0, buf.baseAddress)
        }
    }

    private func createRenderContext(_ handle: OpaquePointer) -> Bool {
        // Software renderer (media_kit TextureSW): "sw" + the four
        // SW_* params at render time. Must run on the main thread
        // (the display layer lives there).
        // The API-type string must stay alive while mpv reads it:
        // ("sw" as NSString).utf8String points into a temporary
        // NSString that dies at the end of the statement, leaving a
        // dangling pointer for mpv_render_context_create to read
        // (a live-open crash vector — the read can hit freed memory).
        // Hold the NSString in a local and extend its lifetime
        // across the create call.
        var ctx: OpaquePointer?
        let apiString = "sw" as NSString
        let api = UnsafeMutableRawPointer(mutating: apiString.utf8String)
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        let created = withExtendedLifetime(apiString) {
            mpv_render_context_create(&ctx, handle, &params)
        }
        guard created >= 0, let ctx = ctx else { return false }
        renderContext = ctx
        mpv_render_context_set_update_callback(ctx, { cb in
            guard let cb = cb else { return }
            let backend = Unmanaged<MpvPlayerBackend>.fromOpaque(cb).takeUnretainedValue()
            backend.renderQueue.async { backend.renderIfNeeded() }
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            while !self.isShutdown {
                guard let handle = self.mpvHandle else { break }
                guard let event = mpv_wait_event(handle, 0.5) else { continue }
                let eventId = event.pointee.event_id
                if eventId == MPV_EVENT_NONE { continue }
                if eventId == MPV_EVENT_SHUTDOWN { break }
                self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            if !didEmitPrepared {
                didEmitPrepared = true
                emit(.prepared)
            }
        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { break }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            switch end.reason {
            case MPV_END_FILE_REASON_EOF:
                emit(.finished(.ended))
            case MPV_END_FILE_REASON_ERROR:
                emit(.finished(.error))
            case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
                break
            default:
                break
            }
        case MPV_EVENT_VIDEO_RECONFIG:
            readVideoSize()
            if !didEmitFirstFrame {
                didEmitFirstFrame = true
                emit(.firstFrame)
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { break }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let namePtr = prop.name else { break }
            let name = String(cString: namePtr)
            switch name {
            case "pause":
                guard prop.format == MPV_FORMAT_FLAG, let p = prop.data else { break }
                let paused = p.assumingMemoryBound(to: Int32.self).pointee
                emit(paused == 0 ? .playing : .paused)
            case "dwidth", "dheight":
                readVideoSize()
            default:
                break
            }
        default:
            break
        }
    }

    private func readVideoSize() {
        guard let handle = mpvHandle else { return }
        var w: Int64 = 0, h: Int64 = 0
        guard mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &w) >= 0,
              mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &h) >= 0,
              w > 0, h > 0 else { return }
        let size = CGSize(width: CGFloat(w), height: CGFloat(h))
        if size != videoSize {
            videoSize = size
            DispatchQueue.main.async { [weak self] in
                self?.onVideoSize?(size)
            }
        }
    }

    private func emit(_ event: PlayerBackendEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - Software rendering

    @objc private func appDidEnterBackground() {
        isBackgrounded = true
    }

    @objc private func appWillEnterForeground() {
        isBackgrounded = false
    }

    private func renderIfNeeded() {
        guard let ctx = renderContext, !isShutdown, !isBackgrounded else { return }
        // Render on every update callback (media_kit TextureSW does
        // the same): the callback only fires when mpv has a new frame
        // or a redraw request, so there is no idle re-render loop.
        _ = mpv_render_context_update(ctx)
        // Render at the video's native size, capped at 1080p: the
        // display layer scales to the view; rendering bigger only
        // burns CPU.
        var size = videoSize
        if size.width <= 0 || size.height <= 0 {
            // No video size yet (audio-only moment / before reconfig).
            return
        }
        if size.width > 1920 || size.height > 1920 {
            let scale = min(1920 / size.width, 1920 / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        size = CGSize(width: max(2, Int(size.width) & ~1), height: max(2, Int(size.height) & ~1))
        guard let buffer = nextPixelBuffer(size: size) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var ssize: [Int32] = [Int32(size.width), Int32(size.height)]
        var pitch = Int(CVPixelBufferGetBytesPerRow(buffer))
        let format = "bgr0"
        ssize.withUnsafeMutableBytes { ssizePtr in
            format.withCString { formatPtr in
                withUnsafeMutablePointer(to: &pitch) { pitchPtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: ssizePtr.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: formatPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: pitchPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(ctx, &params)
                }
            }
        }
        enqueue(buffer: buffer)
    }

    private func nextPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        if poolSize != size || pixelBuffers.isEmpty {
            // (Re)build the triple pool for this size.
            pixelBuffers.removeAll()
            formatDescription = nil
            poolSize = size
            poolIndex = 0
            for _ in 0..<3 {
                guard let buffer = makePixelBuffer(size: size) else { return nil }
                pixelBuffers.append(buffer)
            }
        }
        let buffer = pixelBuffers[poolIndex]
        poolIndex = (poolIndex + 1) % pixelBuffers.count
        return buffer
    }

    private func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer = buffer else { return nil }
        return buffer
    }

    private func enqueue(buffer: CVPixelBuffer) {
        if formatDescription == nil {
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &desc
            ) == noErr, let desc = desc else { return }
            formatDescription = desc
        }
        guard let desc = formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer = sampleBuffer else { return }
        guard let layer = containerView.displayLayer else { return }
        if layer.status == .failed {
            // A failed layer drops everything until flushed.
            layer.flush()
        }
        if layer.isReadyForMoreMediaData {
            layer.enqueue(sampleBuffer)
        }
    }
}
