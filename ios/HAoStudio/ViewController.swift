import UIKit
import WebKit
import AVFoundation

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var loadingView: UIView!
    // Launch splash state (standalone v1, animation #4 — gentle
    // fade + float, Apple-like): the logo fades in from white and
    // floats up slightly, a soft shadow grows beneath it, and the red
    // live dot breathes once. ~1.5s total. The splash only fades when
    // BOTH the animation is done AND the page has loaded, so a slow
    // page never cuts the animation short and a fast page never
    // leaves a lingering splash.
    private var splashLogoView: UIImageView?
    private var splashShadowView: UIImageView?
    private var splashSpinner: UIActivityIndicatorView?
    private var splashSub: UILabel?
    private var splashDot: UIView?
    private var splashDotGlow: UIImageView?
    private var splashStarted = false
    private var splashDone = false
    private var pageLoaded = false
    private var nativePlayerHandler: NativePlayerMessageHandler?
    private var nativeFetchHandler: NativeFetchMessageHandler?
    private var clearCacheHandler: ClearCacheMessageHandler?
    private var nativeMusicHandler: NativeMusicMessageHandler?
    private var haoUpdateHandler: HaoUpdateMessageHandler?
    // Standalone v1: zero server connection. The frontend is bundled
    // (HAoStudio/web/index.html) and loaded with loadFileURL; there is
    // no shop URL, no login, no /api/* calls of any kind.
    // TMDB key: read once from the bundled tmdb-config.json (empty by
    // default; injected at build time from the TMDB_API_KEY env var)
    // and exposed to JS as window.__HAO_TMDB_KEY__. JS contract (for
    // the (a) line): window.HaoSources.getTmdbKey() returns the user's
    // own key from Settings first, else window.__HAO_TMDB_KEY__, else
    // "" (TMDB enrichment is then skipped; CMS data still works).
    private static func bundledTmdbKey() -> String {
        guard let url = Bundle.main.url(forResource: "tmdb-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["tmdb_api_key"] as? String else { return "" }
        return key.trimmingCharacters(in: .whitespaces)
    }

    // Background / interruption resume: whether the web music was playing
    // when the app went away, so it can be resumed on return. Captured
    // from the web page's `playing` variable at willResignActive /
    // didEnterBackground — the earliest signals, before the system gets
    // a chance to pause <audio> (which would flip `playing` to false
    // and lose the intent for good).
    private var wasPlayingBeforeBackground = false
    private var audioResumeRetries = 0
    // Whether the app's AVAudioSession is currently active. The session
    // is activated once at launch and stays active while music plays
    // (background playback proves it); it is only deactivated by a real
    // audio interruption. Re-asserting setActive(true) on an already
    // active session during the background->foreground transition is
    // unnecessary — and it is the one Swift-side audio mutation on that
    // path, so it is the prime suspect for the brief pause the user
    // hears when re-entering the app (the <audio> element pauses, then
    // the web auto-resume restarts it). reactivateAudioSession() is now
    // a no-op while this is true, so foreground entry touches nothing.
    private var audioSessionActive = false
    // Settings -> native halves (standalone settings rebuild):
    // keepScreenOn mirrors the web "屏幕常亮" switch
    // (localStorage hao_keep_screen, web default ON). The idle timer
    // is only disabled while something is actually playing (native
    // music, web <audio> fallback, or a live/VOD player on screen),
    // never just because the switch is on — the switch is a
    // permission, playback is the trigger. Default true to match the
    // web default; the real value is synced from the web page at
    // launch (didFinish) and on every toggle (nativePlayer
    // {kind:'keepScreen', enabled} — web already posts this).
    private var keepScreenOn = true
    // Whether the web <audio> element is currently playing (tracked
    // from the nowPlaying messages). Only used for the idle timer when
    // the native AVPlayer does NOT own the track (fallback path).
    private var webMusicPlaying = false
    // When the app last entered the foreground. A `playing:false`
    // nowPlaying message that arrives within 2s of entering the
    // foreground is the SYSTEM pausing <audio> during the transition
    // (background music stops the moment the app opens), not the user
    // pausing — so it must NOT clear wasPlayingBeforeBackground, or
    // the resume never runs and the song stays stopped (bug 2026-11-15:
    // "后台在放歌 然后点进软件 歌就会自动暂停", v11.5). Only a pause
    // after the app has been continuously active for >2s is a real
    // user pause.
    private var lastEnteredForegroundAt = Date.distantPast
    private var audioObservers: [NSObjectProtocol] = []

    deinit {
        for token in audioObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Keep audio playing in the background (lock screen / Control Center).
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            print("Audio session error: \(error)")
        }

        // Resume music across background / foreground and audio
        // interruptions (call, Siri): the audio session can be
        // deactivated while the app is away and the web <audio> is
        // paused by the system — without re-activating the session and
        // resuming, the song stays stopped after the user comes back.
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.captureWebPlayingState() })
        audioObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.captureWebPlayingState() })
        // Background-play preference (settings "后台播放", web default
        // ON): when OFF, the native music player must pause on
        // backgrounding instead of playing on through the audio
        // session — the web <audio> path already pauses itself in
        // JS; this is the native half.
        audioObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.applyBackgroundPlayPreference() })
        audioObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.appWillEnterForeground() })
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in self?.handleAudioInterruption(n) })

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Bridge for the native player: the web page sees
        // window.__HAO_NATIVE__ and posts stream URLs to `nativePlayer`.
        // ALL live rooms go native through ONE ijkplayer (FFmpeg)
        // player, like Pure Live — HLS (Bilibili / Douyin / Huya) and
        // FLV (Kuaishou / Douyu) alike, no double loading; online
        // video (VOD) goes native when the user taps the landscape
        // button, so the native player shows danmaku too. Music stays
        // in the web page.
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: "window.__HAO_NATIVE__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        let tmdbKeyLiteral = (try? JSONEncoder().encode(Self.bundledTmdbKey()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        userContentController.addUserScript(WKUserScript(
            source: "window.__HAO_TMDB_KEY__ = \(tmdbKeyLiteral);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        let nativeHandler = NativePlayerMessageHandler()
        nativeHandler.viewController = self
        userContentController.add(nativeHandler, name: "nativePlayer")
        self.nativePlayerHandler = nativeHandler
        // Direct API bridge: the web page posts {id, url, method,
        // headers, body, timeout} to `nativeFetch` and URLSession
        // fetches it (no CORS in native code), then calls back with
        // window.__nativeFetchResult(id, status, body). Only
        // allowlisted API hosts are fetched; cookies are kept per host.
        let fetchHandler = NativeFetchMessageHandler()
        fetchHandler.viewController = self
        userContentController.add(fetchHandler, name: "nativeFetch")
        self.nativeFetchHandler = fetchHandler
        // Clear cache: the web page posts {} to `clearCache` and this wipes
        // ONLY the web caches (disk/memory/offline app cache). It deliberately
        // does NOT touch localStorage / cookies / session storage, so local
        // data (playlists, settings, sources) survives. Calls back with
        // window.__clearCacheDone() when finished.
        let cacheHandler = ClearCacheMessageHandler()
        cacheHandler.viewController = self
        userContentController.add(cacheHandler, name: "clearCache")
        self.clearCacheHandler = cacheHandler
        // Native music player (v11.9): the web <audio> element cannot
        // achieve true zero pause on foreground entry (the WebContent
        // media pipeline pauses and resumes — see NativeMusicPlayer.swift
        // for the evidence). Music output moves to a native AVPlayer;
        // the web page keeps the queue / lyrics / UI and posts stream
        // URLs here. The web <audio> stays as the fallback.
        let musicHandler = NativeMusicMessageHandler()
        musicHandler.viewController = self
        userContentController.add(musicHandler, name: "nativeMusic")
        self.nativeMusicHandler = musicHandler
        // Manual update check from the settings page: the web page
        // posts {} to `haoUpdate` and this runs HaoUpdater.checkManually
        // (shows an alert with the changelog + download, or "up to date").
        let updateHandler = HaoUpdateMessageHandler()
        updateHandler.viewController = self
        userContentController.add(updateHandler, name: "haoUpdate")
        self.haoUpdateHandler = updateHandler
        config.userContentController = userContentController
        // Allow the page to use the full screen.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // Let the shop's own long-press / swipe gestures work.
        webView.allowsLinkPreview = false
        self.webView = webView
        // The native music player posts position/state back into this
        // web view (progress bar, lyrics, play state).
        NativeMusicPlayer.shared.webView = webView
        // Keep-screen: re-apply the idle timer whenever the native
        // music play state changes (play / pause / lock-screen pause /
        // interruption), so a paused track lets the screen lock again.
        NativeMusicPlayer.shared.onPlayingStateChanged = { [weak self] in self?.applyIdleTimer() }
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Launch splash (standalone v1, animation #4 — gentle fade +
        // float, Apple-like, chosen by chen 2026-11-16): the approved
        // logo (white bg, black 3D note + play triangle + red live
        // dot) fades in very gently from pure white and floats up
        // slightly, a soft shadow grows beneath it, and the red dot
        // breathes with a slow, subtle pulse. Mark only — no wordmark,
        // exactly like the reference video. The LaunchScreen is blank
        // white too, so the system splash hands over to this view's
        // first frame (logo alpha 0 = pure white) with no flash.
        // ~1.5s total, then the splash fades when the page has loaded
        // (or shows a spinner while waiting).
        let loadingView = UIView()
        loadingView.backgroundColor = .white
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let logoView = UIImageView(image: UIImage(named: "Logo"))
        logoView.contentMode = .scaleAspectFit
        logoView.translatesAutoresizingMaskIntoConstraints = false
        // First frame is pure white: the logo starts invisible, 22pt
        // low and 3% small, and fades/floats into place.
        logoView.alpha = 0
        logoView.transform = CGAffineTransform(translationX: 0, y: 22).scaledBy(x: 0.97, y: 0.97)
        loadingView.addSubview(logoView)
        // Soft ground shadow, grown under the logo as it floats up.
        let shadowView = UIImageView(image: Self.radialGlowImage(size: CGSize(width: 220, height: 64), color: .black, maxAlpha: 0.32))
        shadowView.translatesAutoresizingMaskIntoConstraints = false
        shadowView.alpha = 0
        shadowView.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        loadingView.addSubview(shadowView)
        // Shown only if the page is still loading after the splash
        // animation finishes (normally instant — the page is local).
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .systemRed
        spinner.alpha = 0
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(spinner)
        let sub = UILabel()
        sub.text = "正在加载…"
        sub.font = .systemFont(ofSize: 14)
        sub.textColor = .gray
        sub.alpha = 0
        sub.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(sub)
        NSLayoutConstraint.activate([
            logoView.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -30),
            logoView.widthAnchor.constraint(equalToConstant: 180),
            logoView.heightAnchor.constraint(equalToConstant: 180),
            shadowView.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            shadowView.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: -4),
            shadowView.widthAnchor.constraint(equalToConstant: 220),
            shadowView.heightAnchor.constraint(equalToConstant: 64),
            spinner.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 92),
            sub.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            sub.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8)
        ])
        self.loadingView = loadingView
        self.splashLogoView = logoView
        self.splashShadowView = shadowView
        self.splashSpinner = spinner
        self.splashSub = sub

        // Load the bundled frontend (no network, no server). The web
        // directory is the read-access root so index.html can load its
        // local app.js / style.css / assets. If the bundle is missing
        // web/index.html (packaging error), show it on the loading
        // screen instead of a black view.
        if let pageURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web"),
           let webDir = Bundle.main.url(forResource: "web", withExtension: nil) {
            webView.loadFileURL(pageURL, allowingReadAccessTo: webDir)
        } else {
            sub.text = "本地页面缺失（web/index.html 未打进包）"
        }

        // NOTE: no native launch update check here on purpose. The web
        // page owns the single auto-check channel (haoAutoCheckUpdate:
        // 20h throttle, skip-aware via hao_skip_update). A native
        // launch check would double-prompt and ignore a version the
        // user skipped in Settings. Manual check still works via the
        // `haoUpdate` bridge -> HaoUpdater.checkManually.
        // HaoUpdater.scheduleLaunchCheck()  // intentionally disabled (S1)
    }

    // The app page is a local file:// document: everything local
    // stays in the web view; a tapped http(s) link opens in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        maybeHideLoading()
        // Capture the web view's UA once, so the native music player can
        // send the same UA to music CDNs that the <audio> element used
        // to send (some reject non-browser UAs).
        if NativeMusicPlayer.shared.userAgent == nil {
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                if let ua = result as? String, !ua.isEmpty {
                    NativeMusicPlayer.shared.userAgent = ua
                }
            }
        }
        // Sync the two settings the Swift side owns a native half of
        // from the web page's localStorage (the web page is the source
        // of truth; the toggles live there). typeof-guarded: a missing
        // function keeps the Swift-side default (true, matching the
        // web default) instead of crashing the read.
        webView.evaluateJavaScript("typeof haoKeepScreen==='function'?haoKeepScreen():true") { [weak self] result, _ in
            if let on = result as? Bool { self?.setKeepScreenOn(on) }
        }
        webView.evaluateJavaScript("typeof haoBgPlay==='function'?haoBgPlay():true") { result, _ in
            if let on = result as? Bool { NativeMusicPlayer.shared.setBackgroundPlayEnabled(on) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded = true
        maybeHideLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoaded = true
        maybeHideLoading()
    }

    private func maybeHideLoading() {
        guard pageLoaded else { return }
        // If layout never ran (page loaded before the first layout),
        // there is no splash to wait for — hide immediately.
        guard splashStarted else { hideLoading(); return }
        guard splashDone else { return }
        hideLoading()
    }

    private func hideLoading() {
        guard let loadingView = loadingView else { return }
        self.loadingView = nil
        splashLogoView = nil
        splashShadowView = nil
        splashSpinner = nil
        splashSub = nil
        splashDot = nil
        splashDotGlow = nil
        UIView.animate(withDuration: 0.3, animations: {
            loadingView.alpha = 0
        }, completion: { _ in
            loadingView.removeFromSuperview()
        })
    }

    // MARK: - Launch splash animation

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !splashStarted, let logoView = splashLogoView else { return }
        splashStarted = true
        layoutSplashOverlays(in: logoView)
        runSplashAnimation()
    }

    // Soft radial glow image (black ground shadow / red dot halo):
    // a circle fading from maxAlpha at the centre to transparent at
    // the edge, squashed vertically into an ellipse when the size is
    // wider than tall. Generated in code so no extra asset is needed.
    private static func radialGlowImage(size: CGSize, color: UIColor, maxAlpha: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.scaleBy(x: 1, y: size.height / size.width)
            let colors = [color.withAlphaComponent(maxAlpha).cgColor,
                          color.withAlphaComponent(0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawRadialGradient(grad, startCenter: .zero, startRadius: 0,
                                      endCenter: .zero, endRadius: size.width / 2, options: [])
            }
            cg.restoreGState()
        }
    }

    private func layoutSplashOverlays(in logoView: UIImageView) {
        let w = logoView.bounds.width
        guard w > 0 else { return }
        // Red live-dot overlay, centred on the logo's own red dot
        // (dot centre ≈ 0.678W / 0.409H of the square logo, diameter
        // ≈ 0.069W). It starts invisible and small, fades/scales in
        // with the logo, then breathes once (scale + soft red glow).
        // The underlying logo dot stays put, so the overlay reads as
        // the dot itself throbbing.
        let d = w * 0.069
        let dot = UIView(frame: CGRect(x: w * 0.678 - d / 2, y: w * 0.409 - d / 2, width: d, height: d))
        dot.backgroundColor = UIColor(red: 0.96, green: 0.20, blue: 0.20, alpha: 1)
        dot.layer.cornerRadius = d / 2
        dot.alpha = 0
        dot.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        dot.isUserInteractionEnabled = false
        logoView.addSubview(dot)
        splashDot = dot
        // Soft red glow behind the dot (the "breathing" halo in the
        // reference video): a radial red gradient, alpha animated.
        let g = w * 0.22
        let glow = UIImageView(image: Self.radialGlowImage(size: CGSize(width: g, height: g), color: UIColor(red: 0.96, green: 0.20, blue: 0.20, alpha: 1), maxAlpha: 0.85))
        glow.frame = CGRect(x: w * 0.678 - g / 2, y: w * 0.409 - g / 2, width: g, height: g)
        glow.alpha = 0
        glow.isUserInteractionEnabled = false
        logoView.insertSubview(glow, belowSubview: dot)
        splashDotGlow = glow
    }

    private func runSplashAnimation() {
        guard let logoView = splashLogoView else { return }
        // Animation #4 (gentle fade + float, Apple-like) — matches the
        // reference video frame for frame:
        //  0.0-1.0s  logo fades in from white and floats up 22pt
        //            (ease-out, 0.97 -> 1.0 scale);
        //  0.15-1.0s soft shadow grows beneath it (alpha + scale);
        //  0.7-1.0s  red dot fades/scales in;
        //  0.9-1.5s  dot breathes once, slow and subtle (scale
        //            1 -> 1.12, glow halo grows) — the splash fade-out
        //            at 1.5s is the exhale.
        UIView.animate(withDuration: 1.0, delay: 0, options: [.curveEaseOut], animations: {
            logoView.alpha = 1
            logoView.transform = .identity
        })
        if let shadow = splashShadowView {
            UIView.animate(withDuration: 0.85, delay: 0.15, options: [.curveEaseOut], animations: {
                shadow.alpha = 1
                shadow.transform = .identity
            })
        }
        if let dot = splashDot {
            UIView.animate(withDuration: 0.3, delay: 0.7, options: [.curveEaseOut], animations: {
                dot.alpha = 1
                dot.transform = .identity
            })
        }
        if let dot = splashDot, let glow = splashDotGlow {
            UIView.animate(withDuration: 0.6, delay: 0.9, options: [.curveEaseInOut], animations: {
                dot.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                glow.alpha = 0.55
            })
        }
        // 4. Finish at ~1.5s: fade out if the page is ready, otherwise
        // reveal the spinner and wait for the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.splashDone = true
            if self.pageLoaded {
                self.hideLoading()
            } else {
                self.splashSpinner?.startAnimating()
                UIView.animate(withDuration: 0.25) {
                    self.splashSpinner?.alpha = 1
                    self.splashSub?.alpha = 1
                }
            }
        }
    }

    // VOD/live danmaku endpoint (standalone v1): the web page may
    // send dm.endpoint — the user-configured danmaku endpoint from
    // HaoSources.getDanmakuEndpoint() (default: empty = Bilibili direct
    // only, no ext-danmaku server). Returns nil when no endpoint is
    // configured, so callers fall back to the localhost placeholder
    // that fetchDanmaku refuses to fetch from.
    func danmakuBaseURL(from dm: [String: Any]) -> URL? {
        guard let ep = dm["endpoint"] as? String,
              !ep.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: ep.trimmingCharacters(in: .whitespaces)) else { return nil }
        return url
    }

    // Called from the web page (any live room) to play the stream in the
    // native player, direct from the platform CDN. If a live player is
    // already on screen (e.g. the user switched quality in the web UI),
    // the stream is swapped in place instead of presenting a second
    // player (the ijkplayer instance is recreated with the new URL in
    // the same view). `format` is 'hls' or 'flv' from the web page; it
    // is accepted for compatibility but no longer picks an engine —
    // ijkplayer plays both.
    func presentNativePlayer(url: URL, title: String, platform: String, qualities: [LiveQuality] = [], format: String = "", coverURL: URL? = nil, danmaku: DanmakuConfig? = nil, roomId: String = "") {
        if let existing = presentedViewController as? NativePlayerViewController, existing.isLive {
            if existing.isBeingDismissed {
                // Old player is mid-dismiss (user just closed it and tapped
                // a room at once). Don't drop the request — retry after the
                // dismiss animation finishes so the new room actually opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.presentNativePlayer(url: url, title: title, platform: platform, qualities: qualities, format: format, coverURL: coverURL, danmaku: danmaku, roomId: roomId)
                }
                return
            }
            // Room / quality switch reuses this player: apply the web
            // page's current danmaku settings too, so a position change
            // made on the web page is not lost on the switch.
            if let d = danmaku { existing.applyDanmakuSettings(d) }
            existing.updateStream(url: url, qualities: qualities, format: format, title: title, platform: platform, roomId: roomId)
            return
        }
        if let existing = presentedViewController as? NativePlayerViewController {
            // A VOD player is on screen (the branch above only reuses
            // a live one): dismiss it first, then open the live room
            // after the dismiss — presenting while another player is
            // on screen fails silently in UIKit.
            if existing.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.presentNativePlayer(url: url, title: title, platform: platform, qualities: qualities, format: format, coverURL: coverURL, danmaku: danmaku, roomId: roomId)
                }
            } else {
                existing.dismiss(animated: true) { [weak self] in
                    self?.presentNativePlayer(url: url, title: title, platform: platform, qualities: qualities, format: format, coverURL: coverURL, danmaku: danmaku, roomId: roomId)
                }
            }
            return
        }
        let playerVC = NativePlayerViewController(streamURL: url, title: title, platform: platform, qualities: qualities, format: format, coverURL: coverURL, danmaku: danmaku, roomId: roomId)
        // When the live player closes, tell the web page so it clears
        // the native-post dedupe key — otherwise reopening the same
        // room within 10s is blocked and the room "can't be entered".
        playerVC.onClose = { [weak self] seconds in
            guard let self = self, let webView = self.webView else { return }
            // Player gone: the screen may lock again.
            self.applyIdleTimer()
            let t = String(format: "%.1f", seconds)
            webView.evaluateJavaScript("if(window.syncNativePlayerPosition){window.syncNativePlayerPosition(\(t));}", completionHandler: nil)
            // The native player clears Now Playing info on teardown;
            // re-publish the web track after the dismiss so the car /
            // lock screen keep showing the music (delayed past teardown).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript("if(window.updateMediaSession){window.updateMediaSession();}", completionHandler: nil)
            }
        }
        // Live playback finally failed (same-URL auto-retry exhausted):
        // ask the web page for a FRESH play URL and re-post it. The
        // web side throttles this to once per 60s.
        playerVC.onLiveFailed = { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript("if(window.__nativeLiveFailed){window.__nativeLiveFailed();}", completionHandler: nil)
        }
        // Danmaku settings changed in the player (gear panel): persist
        // to the web page's localStorage so the next player open uses
        // the same position / opacity / speed.
        playerVC.onDanmakuSettingsChanged = { [weak self] pos, op, sp in
            guard let webView = self?.webView else { return }
            let js = "dmPos='\(pos)';localStorage.setItem('dmPos','\(pos)');dmOpacity=\(op);localStorage.setItem('dmOpacity','\(op)');dmSpeed=\(sp);localStorage.setItem('dmSpeed','\(sp)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        playerVC.onPlayerEngineChanged = { [weak self] engine in
            self?.syncPlayerEngineToWeb(engine)
        }
        // Live danmaku bridge: the web page runs Bilibili WS / Kuaishou
        // polling and buffers fresh items; pull them into the native
        // player's danmaku layer (Pure Live shows danmaku on the video).
        playerVC.liveDanmakuPull = { [weak self] completion in
            guard let webView = self?.webView else { completion([]); return }
            webView.evaluateJavaScript("window.__liveDmDrain ? window.__liveDmDrain() : []") { result, _ in
                completion(result as? [String] ?? [])
            }
        }
        // Player follow button (landscape) + room-switch gesture:
        // the web page owns both (toggleLiveFollow / liveSwipeNext);
        // the player only asks. Follow state is synced from the web's
        // liveFollowed flag at present time and after every tap.
        playerVC.onFollowTapped = { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript("if(window.toggleLiveFollow){window.toggleLiveFollow();}") { _, _ in
                webView.evaluateJavaScript("(typeof liveFollowed!=='undefined' && liveFollowed) ? true : false") { result, _ in
                    if let player = self?.presentedViewController as? NativePlayerViewController {
                        player.setFollowed((result as? NSNumber)?.boolValue ?? false)
                    }
                }
            }
        }
        playerVC.onRequestRoomSwitch = { [weak self] dir in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript("if(window.liveSwipeNext){window.liveSwipeNext(\(dir));}", completionHandler: nil)
        }
        // Sync the follow button's initial state from the web page.
        if let webView = self.webView {
            webView.evaluateJavaScript("(typeof liveFollowed!=='undefined' && liveFollowed) ? true : false") { result, _ in
                playerVC.setFollowed((result as? NSNumber)?.boolValue ?? false)
            }
        }
        present(playerVC, animated: true)
        // Live player on screen and playing: the screen stays on
        // (when the keep-screen setting allows it).
        applyIdleTimer()
    }

    // Web music player -> synced-lyrics Live Activity. The song plays
    // in the web page's audio element (the native player is never
    // presented for music); the web page posts song + LRC + position
    // and this drives the same Live Activity the native player uses.
    // Actions: start (song + LRC + position), pause, resume (+position),
    // seek (+position), stop. No-ops on iOS 15 (Live Activities need 16.2).
    func handleMusicLyricsMessage(_ body: [String: Any]) {
        guard #available(iOS 16.2, *) else { return }
        let action = body["action"] as? String ?? ""
        switch action {
        case "start":
            // NO separate music Live Activity (user 2026-11-15: "不要锁屏下面
            // 的那个，要放在一起的") — the lyric line lives INSIDE the system
            // Now Playing card (lock screen + Control Center), written by the
            // web page into the Media Session artist field. Do NOT start a
            // LyricsLiveActivity for music; the card below Now Playing is gone.
            break
        case "pause":
            LyricsLiveActivity.shared.setPlaying(false)
        case "resume":
            if let pos = (body["position"] as? NSNumber)?.doubleValue {
                LyricsLiveActivity.shared.seek(to: pos)
            }
            LyricsLiveActivity.shared.setPlaying(true)
        case "seek":
            if let pos = (body["position"] as? NSNumber)?.doubleValue {
                LyricsLiveActivity.shared.seek(to: pos)
            }
        case "stop":
            LyricsLiveActivity.shared.end(owner: "music")
        default:
            break
        }
    }

    // Web music player -> now-playing intent. Standalone v1 has no
    // widget mirror (the shop build wrote the track into the App Group
    // for the home-screen widget); this only records the user's
    // play/pause intent (wantPlaying) for the foreground-resume path.
    func handleNowPlayingMessage(_ body: [String: Any]) {
        let title = body["title"] as? String ?? ""
        guard !title.isEmpty else { return }
        let artist = body["artist"] as? String ?? ""
        // Cover URLs come from the platforms as absolute URLs; a
        // relative path (local asset) is used as-is — there is no
        // server base to prefix in the standalone build.
        let cover = body["cover"] as? String ?? ""
        let songId = body["songId"] as? String ?? ""
        let playing = (body["playing"] as? NSNumber)?.boolValue ?? false
        // Web <audio> fallback path: the native AVPlayer does not own
        // the track here, so the idle timer needs the web play state.
        // (When native owns it, NativeMusicPlayer.isPlaying is the
        // source of truth and this flag is ignored by applyIdleTimer's
        // OR — both being true is harmless.)
        webMusicPlaying = playing
        applyIdleTimer()
        // Record "the user wants music playing" here too (fix
        // 2026-11-15): the web posts this on every play/pause, so it
        // does not depend on the async read at background time, which
        // can miss when the web process is already suspended. The web
        // now also sends `wantPlaying` — the user's intent, set ONLY
        // by user actions (play/pause button, track select, Media
        // Session), never by a pause event — so a system pause posts
        // playing:false with wantPlaying:true and the intent survives.
        // A user pause posts wantPlaying:false and the intent is
        // dropped. (v11.7: the v11.6 2s foreground window was fragile
        // — a system pause landing after the window cleared the flag
        // and the resume never ran, so the song stayed stopped even
        // though the user never paused. The window is kept only as a
        // fallback for a web page that does not send wantPlaying.)
        if let wantNum = body["wantPlaying"] as? NSNumber {
            wasPlayingBeforeBackground = wantNum.boolValue
        } else if playing {
            wasPlayingBeforeBackground = true
        } else if UIApplication.shared.applicationState == .active && Date().timeIntervalSince(lastEnteredForegroundAt) > 2.0 {
            wasPlayingBeforeBackground = false
        }
        // NOTE (standalone v1): the shop build mirrored the track into
        // the App Group for the home-screen widget. The widget is not
        // shipped in v1, so there is no mirror here — the nowPlaying
        // message still drives wasPlayingBeforeBackground above, which
        // the foreground-resume path depends on.
        _ = (cover, songId)
        _ = (title, artist, playing)
    }

    // Called from the web page (online video / VOD) when the user taps the
    // landscape button inside the app: plays the episode's HLS stream in
    // the native player, with native danmaku. When the player closes, the
    // web page's video is re-synced to where the native player stopped.
    func presentNativeVODPlayer(url: URL, title: String, startPosition: Double, danmaku: DanmakuConfig, lyrics: String = "", coverURL: URL? = nil, speed: Double = 1) {
        if let existing = presentedViewController as? NativePlayerViewController {
            // A player is already on screen (a live room, or a
            // double-tapped VOD): presenting a second one fails
            // silently in UIKit, so close the old one first and open
            // the new one after the dismiss.
            if existing.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.presentNativeVODPlayer(url: url, title: title, startPosition: startPosition, danmaku: danmaku, lyrics: lyrics, coverURL: coverURL, speed: speed)
                }
            } else {
                existing.dismiss(animated: true) { [weak self] in
                    self?.presentNativeVODPlayer(url: url, title: title, startPosition: startPosition, danmaku: danmaku, lyrics: lyrics, coverURL: coverURL, speed: speed)
                }
            }
            return
        }
        var config = NativePlayerConfig(url: url, title: title, platform: "video", kind: "vod", startPosition: startPosition, danmaku: danmaku)
        config.lyrics = lyrics
        config.coverURL = coverURL
        config.playbackSpeed = speed
        let playerVC = NativePlayerViewController(config: config)
        playerVC.onClose = { [weak self] seconds in
            guard let self = self, let webView = self.webView else { return }
            // Player gone: the screen may lock again.
            self.applyIdleTimer()
            let t = String(format: "%.1f", seconds)
            webView.evaluateJavaScript("if(window.syncNativePlayerPosition){window.syncNativePlayerPosition(\(t));}", completionHandler: nil)
            // The native player clears Now Playing info on teardown;
            // re-publish the web track after the dismiss so the car /
            // lock screen keep showing the music (delayed past teardown).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript("if(window.updateMediaSession){window.updateMediaSession();}", completionHandler: nil)
            }
        }
        // Danmaku settings changed in the player (gear panel): persist
        // to the web page's localStorage so the next player open uses
        // the same position / opacity / speed.
        playerVC.onDanmakuSettingsChanged = { [weak self] pos, op, sp in
            guard let webView = self?.webView else { return }
            let js = "dmPos='\(pos)';localStorage.setItem('dmPos','\(pos)');dmOpacity=\(op);localStorage.setItem('dmOpacity','\(op)');dmSpeed=\(sp);localStorage.setItem('dmSpeed','\(sp)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        playerVC.onPlayerEngineChanged = { [weak self] engine in
            self?.syncPlayerEngineToWeb(engine)
        }
        // Playback speed changed in the player (settings panel or
        // long-press release): sync back to the web page so the web
        // player's speed button + localStorage stay in step.
        playerVC.onSpeedChanged = { [weak self] rate in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript("if(window.__setVodSpeed){window.__setVodSpeed(\(rate));}", completionHandler: nil)
        }
        present(playerVC, animated: true)
        applyIdleTimer()
    }

    // The player itself switched the engine (AVPlayer + FLV live: the
    // retry button moves to MPV). Write the new engine to the web
    // page's localStorage so Settings shows the same engine.
    func syncPlayerEngineToWeb(_ engine: String) {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("localStorage.setItem('hao_player_engine','\(engine)');if(window.haoRefreshSettings){window.haoRefreshSettings();}", completionHandler: nil)
    }

    // VOD danmaku fed from the web page (Bilibili direct): the player
    // never fetches danmaku itself. No-op when no player is on screen.
    func feedVodDanmakuToPlayer(_ items: [(Double, String)]) {
        if let player = presentedViewController as? NativePlayerViewController {
            player.feedVodDanmaku(items)
        }
    }

    // MARK: - Settings native halves (keep screen / background play)

    // Called by the nativePlayer handler for {kind:'keepScreen',
    // enabled} (web haoSetKeepScreenOn posts this on every toggle)
    // and by the launch sync in didFinish.
    func setKeepScreenOn(_ on: Bool) {
        keepScreenOn = on
        applyIdleTimer()
    }

    // Idle timer follows playback, not just the switch: disabled only
    // while the setting is on AND something is playing (native music,
    // web <audio> fallback, or a live/VOD player on screen and
    // playing). Called on every event that can change either side:
    // keepScreen toggle, music play/pause (onPlayingStateChanged),
    // player present/dismiss, foreground entry.
    func applyIdleTimer() {
        let playerPlaying = (presentedViewController as? NativePlayerViewController)?.isPlaying ?? false
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && (NativeMusicPlayer.shared.isPlaying || webMusicPlaying || playerPlaying)
    }

    // Background-play preference (settings "后台播放"): when OFF, the
    // native music player pauses as the app backgrounds. The intent
    // flag is cleared too, so the foreground-resume path does not
    // restart it — mirroring the web <audio> path, where the page
    // sets wantPlaying=false on hide when the switch is off.
    private func applyBackgroundPlayPreference() {
        guard !NativeMusicPlayer.shared.backgroundPlayEnabled,
              NativeMusicPlayer.shared.isPlaying else { return }
        NativeMusicPlayer.shared.pause()
        wasPlayingBeforeBackground = false
    }

    // MARK: - Background / interruption audio resume

    private func reactivateAudioSession() {
        // Only (re-)activate when the session is known to be inactive.
        // The session stays active across background/foreground while
        // music plays, so re-asserting setActive(true) on every
        // foreground entry is unnecessary — and re-asserting an
        // already-active session during the background->foreground
        // transition can briefly reconfigure the audio route and pause
        // the WebKit <audio> element (the brief gap the user hears when
        // re-entering the app). Genuine re-activation still happens:
        // a real interruption sets audioSessionActive=false in .began,
        // so the .ended path below reactivates as before.
        guard !audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActive = true
        } catch {
            print("Audio session re-activate error: \(error)")
        }
    }

    // Snapshot the web player's intent ("the user wants music playing")
    // as early as possible: willResignActive fires before the system
    // gets a chance to pause <audio>. Only ever upgrades the flag to
    // true — a later read that says false means the system already
    // paused it, not that the user did.
    private func captureWebPlayingState() {
        webView?.evaluateJavaScript("typeof playing!=='undefined'&&playing") { [weak self] result, _ in
            if result as? Bool == true {
                self?.wasPlayingBeforeBackground = true
            }
        }
    }

    private func appWillEnterForeground() {
        lastEnteredForegroundAt = Date()
        // The session may have been deactivated while the app was away;
        // re-activate it first so the web audio element is allowed to
        // play again. The web process needs a beat to come back, so the
        // actual resume runs after a short delay.
        reactivateAudioSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.resumeWebMusicIfNeeded()
        }
    }

    // MARK: - Clear cache reply
    // Called by ClearCacheMessageHandler after the WKWebsiteDataStore
    // removal finishes. Runs on the main queue (removeData's completion
    // is delivered there) and tells the web page it may toast + reload.
    func clearCacheDone() {
        webView?.evaluateJavaScript("if(window.__clearCacheDone){window.__clearCacheDone();}")
    }

    // MARK: - Direct API bridge reply
    // Called by NativeFetchMessageHandler on a background queue.
    // The body is JSON-encoded so it is safe to embed in JS.
    // CRASH FIX (v11.3): the old code passed a String as the top-level
    // value to JSONSerialization's object-to-data API. That API
    // only accepts a top-level Array/Dictionary; a String raises an
    // NSException ("Invalid top-level type in JSON write") which
    // Swift's try? CANNOT catch, so the app crashed on EVERY native
    // fetch reply — i.e. on the first tap of play. JSONEncoder encodes
    // a String as a JSON string literal, which is exactly what the JS
    // call below needs as its third argument (web resolves it as
    // {status, text: body}).
    func nativeFetchReply(id: Int, status: Int, body: String) {
        let encoded: String
        if let data = try? JSONEncoder().encode(body),
           let s = String(data: data, encoding: .utf8) {
            encoded = s
        } else {
            encoded = "\"\""
        }
        let js = "if(window.__nativeFetchResult){window.__nativeFetchResult(\(id),\(status),\(encoded));}"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func resumeWebMusicIfNeeded() {
        guard wasPlayingBeforeBackground else { return }
        // The native player (live / VOD) owns the audio while it is on
        // screen — never resume the web music over it.
        guard presentedViewController == nil else { wasPlayingBeforeBackground = false; audioResumeRetries = 0; return }
        // Don't steal the audio from another app the user started while
        // this one was in the background. But don't give up either: the
        // other audio may still be finishing when the interruption-ended
        // event fires, so retry once a second for up to 10s. The flag is
        // only cleared once the resume actually runs or the retries run
        // out — a blocked attempt no longer loses the intent.
        if AVAudioSession.sharedInstance().isOtherAudioPlaying {
            if audioResumeRetries < 10 {
                audioResumeRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.resumeWebMusicIfNeeded()
                }
            } else {
                wasPlayingBeforeBackground = false
                audioResumeRetries = 0
            }
            return
        }
        guard let webView = webView else { return }
        // Native music (v11.9): if the AVPlayer owns the track, resume
        // IT — the web <audio> element is not playing anything, so
        // __resumeAudioIfPlaying would be a no-op. resume() is a no-op
        // while already playing, which is the normal foreground case:
        // the AVPlayer never paused, so nothing happens and there is
        // zero gap. Only a real interruption (call/Siri) leaves it
        // paused, and this is what restarts it.
        if NativeMusicPlayer.shared.isActive {
            reactivateAudioSession()
            NativeMusicPlayer.shared.resume()
            wasPlayingBeforeBackground = false
            audioResumeRetries = 0
            return
        }
        reactivateAudioSession()
        // force=true: the web `playing` variable may already have been
        // flipped to false by the system's own pause during the
        // background/foreground transition, so the Swift-side flag is
        // the source of truth here. A successful play() re-sets
        // `playing` through the web page's own `play` listener (vinyl
        // UI + Media Session + widget all refresh from there — nothing
        // is re-posted from this side).
        webView.evaluateJavaScript("if(window.__resumeAudioIfPlaying){window.__resumeAudioIfPlaying(true);}", completionHandler: nil)
        // VERIFY the resume actually took (fix 2026-11-15): audio.play()
        // can silently fail when the WebContent process is still waking
        // up after a background suspension (its promise rejects and the
        // web side swallows it), and the old code cleared the flag right
        // after the call — so one failed attempt meant the music stayed
        // paused after coming back. Re-check after 1s and retry the
        // resume up to 10 times; only clear the flag once the audio is
        // confirmed playing, or the retries run out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.wasPlayingBeforeBackground else { return }
            self.webView?.evaluateJavaScript("typeof audio!=='undefined'&&!audio.paused") { result, _ in
                if result as? Bool == true {
                    self.wasPlayingBeforeBackground = false
                    self.audioResumeRetries = 0
                } else if self.audioResumeRetries < 10 {
                    self.audioResumeRetries += 1
                    self.resumeWebMusicIfNeeded()
                } else {
                    self.wasPlayingBeforeBackground = false
                    self.audioResumeRetries = 0
                }
            }
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // A call / Siri / alarm is taking the audio. The system
            // deactivates the session here, so mark it inactive — the
            // .ended path will reactivate it. Snapshot the intent now;
            // the web `pause` event that follows would otherwise
            // erase it.
            audioSessionActive = false
            captureWebPlayingState()
        case .ended:
            // iOS only sets .shouldResume for some interruption kinds
            // (e.g. phone calls). Another app's audio ending often
            // comes without it, so don't require it — the
            // wasPlayingBeforeBackground flag already proves the user
            // wanted music, and resumeWebMusicIfNeeded still refuses
            // to steal audio while another app is actually playing.
            reactivateAudioSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.resumeWebMusicIfNeeded()
            }
        @unknown default:
            break
        }
    }
}

// WKScriptMessageHandler for `nativePlayer`. Kept in its own class with a
// weak back-reference so the WKUserContentController does not retain the
// ViewController and create a retain cycle.
private final class NativePlayerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: ViewController?

    // JS values cross the WKScriptMessage bridge as NSNumber / NSString /
    // __NSCFBoolean, but the exact type is not guaranteed: a future web
    // change (or a JSON round-trip) can deliver a Bool as "1", a number
    // as "2023", or a year as 2023. The old code used single-type casts
    // (`as? NSNumber`, `as? String`), so ANY such variation silently
    // fell back to the default — e.g. a string "false" for `enabled`
    // would parse as... nothing, and danmaku would silently use the
    // default. These helpers accept every plausible shape so a type
    // variation can never silently kill danmaku (or any other setting).
    static func dmBool(_ v: Any?, default d: Bool) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "true" || t == "1" || t == "yes" { return true }
            if t == "false" || t == "0" || t == "no" { return false }
        }
        return d
    }
    static func dmDouble(_ v: Any?, default d: Double) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d2 = Double(s.trimmingCharacters(in: .whitespaces)) { return d2 }
        return d
    }
    static func dmInt(_ v: Any?, default d: Int) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return d
    }
    static func dmString(_ v: Any?, default d: String) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return d
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativePlayer",
              let body = message.body as? [String: Any] else { return }
        // Music (web player): no stream URL — the song plays in the
        // web page's audio element. Only the lyrics Live Activity is
        // driven from here (lock screen + Dynamic Island). Handled
        // before the URL guard below, which music messages have no URL for.
        if (body["kind"] as? String) == "music" {
            viewController?.handleMusicLyricsMessage(body)
            return
        }
        if (body["kind"] as? String) == "nowPlaying" {
            viewController?.handleNowPlayingMessage(body)
            return
        }
        // Keep screen (settings "屏幕常亮"): the web page posts
        // {kind:'keepScreen', enabled} on every toggle
        // (haoSetKeepScreenOn). No URL — handled before the URL guard
        // below, like music / nowPlaying. The ViewController applies
        // it as a permission: the idle timer is only disabled while
        // something is actually playing (see applyIdleTimer).
        if (body["kind"] as? String) == "keepScreen" {
            viewController?.setKeepScreenOn(Self.dmBool(body["enabled"], default: true))
            return
        }
        // Player engine (Settings "播放器内核"): the web page posts
        // {kind:'playerEngine', engine:'mpv'|'ijk'|'exo'} on every
        // change (haoSetPlayerEngine). Persist it; if a player is
        // open, rebuild it with the new engine in place (VOD resumes
        // at its position, live just reopens).
        if (body["kind"] as? String) == "playerEngine" {
            PlayerKernel.current = PlayerEngineKey.from(Self.dmString(body["engine"], default: "mpv"))
            if let player = viewController?.presentedViewController as? NativePlayerViewController {
                player.rebuildWithCurrentEngine()
            }
            return
        }
        // VOD danmaku (Bilibili direct): the web page posts
        // {kind:"vodDanmaku", items:[[time, text], ...]} after fetching
        // danmaku itself; feed the items to the on-screen player.
        if (body["kind"] as? String) == "vodDanmaku" {            var items: [(Double, String)] = []
            if let arr = body["items"] as? [[Any]] {
                for e in arr where e.count >= 2 {
                    let t: Double
                    if let n = e[0] as? NSNumber { t = n.doubleValue }
                    else if let s = e[0] as? String, let d = Double(s) { t = d }
                    else { continue }
                    let text = (e[1] as? String) ?? ""
                    if !text.isEmpty { items.append((t, text)) }
                }
            }
            viewController?.feedVodDanmakuToPlayer(items)
            return
        }
        guard let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        let title = body["title"] as? String ?? ""
        let platform = body["platform"] as? String ?? ""
        // Optional cover / poster URL for lock screen artwork.
        let coverURL = (body["cover"] as? String).flatMap { URL(string: $0) }
        if (body["kind"] as? String) == "vod" {
            // Online video (VOD): HLS episode + native danmaku.
            let dm = body["dm"] as? [String: Any] ?? [:]
            let position = (body["position"] as? NSNumber)?.doubleValue ?? 0
            // Playback speed chosen on the web page (0.5–3x). Clamped to
            // the supported range; anything else falls back to 1x.
            let webSpeed = Self.dmDouble(body["speed"], default: 1)
            let speed = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0].contains(webSpeed) ? webSpeed : 1
            let baseURL = viewController?.danmakuBaseURL(from: dm) ?? URL(string: "https://localhost/")!
            let danmaku = DanmakuConfig(
                baseURL: baseURL,
                name: Self.dmString(dm["name"], default: ""),
                episode: Self.dmInt(dm["ep"], default: 1),
                year: Self.dmString(dm["year"], default: ""),
                type: Self.dmString(dm["type"], default: ""),
                enabled: Self.dmBool(dm["enabled"], default: true),
                opacity: Self.dmDouble(dm["opacity"], default: 0.9),
                speed: Self.dmDouble(dm["speed"], default: 1),
                position: Self.dmString(dm["pos"], default: "full"))
            // LRC lyrics for the lyrics Live Activity (normally empty
            // for movies — VOD has danmaku, not song lyrics — but the
            // contract carries it for whatever the web page passes).
            let lyrics = body["lyrics"] as? String ?? ""
            viewController?.presentNativeVODPlayer(url: url, title: title, startPosition: position, danmaku: danmaku, lyrics: lyrics, coverURL: coverURL, speed: speed)
            return
        }
        // Live takes the SAME danmaku settings the web page uses
        // (dm.pos / opacity / speed / enabled, i.e. the global dmPos).
        // Before this the live branch never read body["dm"], so every
        // live room opened at the hardcoded default (full / 0.9 / 1)
        // no matter what position the user had set.
        let dm = body["dm"] as? [String: Any] ?? [:]
        let liveDanmaku = DanmakuConfig(
            baseURL: viewController?.danmakuBaseURL(from: dm) ?? URL(string: "https://localhost/")!,
            name: "", episode: 0, year: "", type: "",
            enabled: Self.dmBool(dm["enabled"], default: true),
            opacity: Self.dmDouble(dm["opacity"], default: 0.9),
            speed: Self.dmDouble(dm["speed"], default: 1),
            position: Self.dmString(dm["pos"], default: "full"))
        viewController?.presentNativePlayer(url: url, title: title, platform: platform, qualities: parseLiveQualities(body["qualities"]), format: body["format"] as? String ?? "", coverURL: coverURL, danmaku: liveDanmaku, roomId: Self.dmString(body["roomId"], default: Self.dmString(body["room"], default: "")))
    }

    // qualities: [{id, name, url, urls[]}] — may be missing or empty.
    private func parseLiveQualities(_ raw: Any?) -> [LiveQuality] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let urlString = d["url"] as? String, let url = URL(string: urlString) else { return nil }
            let urls = (d["urls"] as? [String] ?? []).compactMap { URL(string: $0) }
            return LiveQuality(id: d["id"] as? String ?? "", name: d["name"] as? String ?? "", url: url, urls: urls.isEmpty ? [url] : urls)
        }
    }
}

// WKScriptMessageHandler for `nativeFetch` (Direct-API Phase 2).
// The web page posts {id, url, method, headers, body, timeout} and
// this fetches it with URLSession — native code has no CORS — then
// calls back with window.__nativeFetchResult(id, status, body).
// Only allowlisted API hosts are fetched. Cookies are kept PER HOST
// in memory (never the shared jar): Douyin needs a ttwid cookie primed
// from its homepage, Kuaishou a session cookie from its home list —
// both are captured from Set-Cookie and replayed automatically.
// Kept in its own class with a weak back-reference, like the
// nativePlayer handler, so the user content controller cannot retain
// the ViewController and create a cycle.
private final class NativeFetchMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: ViewController?

    private static let allowedHosts: Set<String> = [
        // music search / lyrics
        "music.163.com", "c.y.qq.com", "songsearch.kugou.com",
        "search.kuwo.cn", "m.kuwo.cn", "www.kuwo.cn", "comment.kuwo.cn",
        "nplserver.kuwo.cn",
        "www.kugou.com", "m.kugou.com",
        // play-url resolvers
        "lxmusicapi.onrender.com", "yy.zddyr.top", "yy1.zddyr.top",
        "music-api.gdstudio.xyz", "metings.qjqq.cn", "ncm.kangqiovo.com",
        "api.yutangxiaowu.cn", "oiapi.net", "music.lzmhhh.com",
        "tang.api.s01s.cn", "c.wwwweb.top", "103.79.184.97",
        // Huibq key source (jsdelivr is CORS-open; the key is public)
        "cdn.jsdelivr.net", "raw.githubusercontent.com", "ghproxy.net",
        // video CMS
        "caiji.moduapi.cc", "api.guangsuapi.com", "jszyapi.com",
        "www.huyaapi.com", "api.xinlangapi.com", "360zy.com",
        "www.hongniuzy2.com", "hhzyapi.com", "www.subozy.com",
        "bfzyapi.com", "jyzyapi.com", "ffzy5.tv", "cj.lziapi.com",
        "api.changzhang.tv", "subocaiji.com", "cj.rycjapi.com",
        "ikunzyapi.com",
        // TMDB (Phase 3: trending + detail go direct; key comes from the
        // server at runtime, never in source or the repo)
        "api.themoviedb.org",
        // Douban detail enrichment (nativeFetch only — Douban sends no
        // CORS headers, so web fetch is blocked; no key or login needed)
        "movie.douban.com", "www.douban.com", "m.douban.com",
        // live
        "api.live.bilibili.com", "api.bilibili.com",
        "live.douyin.com", "webcast.amemv.com",
        "www.huya.com", "m.huya.com",
        // Huya true search (standalone audit: the only host app.js
        // calls via nativeJson that was missing from the list).
        "search.cdn.huya.com",
        "www.douyu.com", "m.douyu.com",
        "live.kuaishou.com", "livev.m.chenzhongtech.com",
        // live-lines.js (Pure Live Big-5 port):
        //   www.douyin.com — Douyin real search (/aweme/v1/web/live/search/)
        //   udblgn.huya.com — Huya anonymous uid (POST /web/anonymousLogin)
        //   log-sdk.ksapisrv.com — Kuaishou misc2 device report
        "www.douyin.com", "udblgn.huya.com", "log-sdk.ksapisrv.com",
    ]

    // host -> cookie name -> value
    private var cookieStore: [String: [String: String]] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeFetch",
              let body = message.body as? [String: Any],
              let id = (body["id"] as? NSNumber)?.intValue,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              Self.allowedHosts.contains(host) else {
            // Refused (bad shape or host not allowlisted): report -1
            // so the web side falls back to the server.
            if let body = message.body as? [String: Any],
               let id = (body["id"] as? NSNumber)?.intValue {
                viewController?.nativeFetchReply(id: id, status: -1, body: "")
            }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = (body["method"] as? String ?? "GET").uppercased()
        let timeoutMs = (body["timeout"] as? NSNumber)?.doubleValue ?? 10000
        req.timeoutInterval = min(max(timeoutMs / 1000.0, 2), 30)
        if let headers = body["headers"] as? [String: String] {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        if let b = body["body"] as? String, !b.isEmpty, req.httpMethod != "GET" {
            req.httpBody = b.data(using: .utf8)
        }
        // Replay this host's stored cookies.
        if let cookies = cookieStore[host], !cookies.isEmpty {
            let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let task = session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self = self else { return }
            // cookieStore is read on the main thread (didReceive), so
            // the capture + reply run here on main too — never read
            // and written from two threads at once.
            DispatchQueue.main.async {
                guard let http = resp as? HTTPURLResponse else {
                    self.viewController?.nativeFetchReply(id: id, status: -1, body: "")
                    return
                }
                // Collect EVERY Set-Cookie header value:
                // value(forHTTPHeaderField:) returns only the first
                // when the server sends several. A Set-Cookie value
                // can hold several cookies separated by ", " (and an
                // Expires date itself contains a comma), so split on
                // ", " and keep only segments whose pre-";" part is
                // a name=value pair.
                var setCookieValues: [String] = []
                for (k, v) in http.allHeaderFields {
                    guard let ks = k as? String, ks.lowercased() == "set-cookie",
                          let vs = v as? String else { continue }
                    setCookieValues.append(vs)
                }
                let raw = setCookieValues.joined(separator: ", ")
                if !raw.isEmpty {
                    var store = self.cookieStore[host] ?? [:]
                    for seg in raw.components(separatedBy: ", ") {
                        let first = seg.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
                        let kv = first.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 {
                            let name = String(kv[0]).trimmingCharacters(in: .whitespaces)
                            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { store[name] = value }
                        }
                    }
                    if !store.isEmpty { self.cookieStore[host] = store }
                }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.viewController?.nativeFetchReply(id: id, status: http.statusCode, body: text)
            }
        }
        task.resume()
    }
}

// WKScriptMessageHandler for `clearCache` (settings: clear cache).
// The web page posts {} and this wipes ONLY the WKWebView caches:
// DiskCache, MemoryCache and OfflineWebApplicationCache. It deliberately
// does NOT remove LocalStorage, Cookies or SessionStorage — the login
// token lives in localStorage, so clearing those would log the user out.
// Calls back with window.__clearCacheDone() when the removal finishes,
// so the web side can toast and reload. Kept in its own class with a
// weak back-reference, like the nativePlayer / nativeFetch handlers.
private final class ClearCacheMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: ViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "clearCache" else { return }
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        WKWebsiteDataStore.default().removeData(
            ofTypes: cacheTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            self?.viewController?.clearCacheDone()
        }
    }
}

// WKScriptMessageHandler for `nativeMusic` (v11.9). The web page posts
// music playback to the native AVPlayer (see NativeMusicPlayer.swift
// for why: the web <audio> element cannot achieve true zero pause on
// foreground entry). Kept in its own class with a weak back-reference,
// like the other handlers, so the user content controller cannot retain
// the ViewController and create a cycle.
private final class NativeMusicMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: ViewController?

    // Lenient bool: the bridge may deliver a Bool, an NSNumber or "1"/"0".
    private static func mutedValue(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "true" || t == "1" || t == "yes" { return true }
            if t == "false" || t == "0" || t == "no" { return false }
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeMusic",
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "play":
            guard let urlString = body["url"] as? String,
                  let url = URL(string: urlString) else { return }
            // The web page sends its current mute state with every
            // play, so a mute set before playback (e.g. restored from
            // last session) sticks on the new AVPlayer item.
            if let m = Self.mutedValue(body["muted"]) { NativeMusicPlayer.shared.setMuted(m) }
            NativeMusicPlayer.shared.play(
                url: url,
                songId: (body["songId"] as? String) ?? "",
                title: (body["title"] as? String) ?? "",
                artist: (body["artist"] as? String) ?? "",
                cover: (body["cover"] as? String) ?? "",
                position: (body["position"] as? NSNumber)?.doubleValue ?? 0)
        case "pause":
            NativeMusicPlayer.shared.pause()
        case "resume":
            NativeMusicPlayer.shared.resume()
        case "toggle":
            NativeMusicPlayer.shared.toggle()
        case "seek":
            NativeMusicPlayer.shared.seek(to: (body["position"] as? NSNumber)?.doubleValue ?? 0)
        case "stop":
            NativeMusicPlayer.shared.stop()
        case "mute":
            if let m = Self.mutedValue(body["muted"]) { NativeMusicPlayer.shared.setMuted(m) }
        case "bgPlay":
            // Background-play preference (settings "后台播放"): the web
            // page posts {kind:'bgPlay', enabled} on every toggle
            // (haoSetBgPlay). Stored on the player; the ViewController
            // pauses it on backgrounding when OFF (see
            // applyBackgroundPlayPreference). Default ON (matches web).
            if let on = Self.mutedValue(body["enabled"]) { NativeMusicPlayer.shared.setBackgroundPlayEnabled(on) }
        default:
            break
        }
    }
}

// WKScriptMessageHandler for `haoUpdate`: the settings page posts {}
// to trigger a manual update check (HaoUpdater.checkManually).
private final class HaoUpdateMessageHandler: NSObject, WKScriptMessageHandler {
    weak var viewController: ViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "haoUpdate" else { return }
        HaoUpdater.checkManually(from: viewController)
    }
}
