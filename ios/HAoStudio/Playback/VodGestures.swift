// HAo Studio 2.0 — VOD gestures (S3, leg A).
//
// One of the four independent VOD pieces (P0-08): this file owns
// ONLY the gesture layer — long-press 2x, double-tap seek, single
// tap to toggle controls. It knows nothing about the driver, the
// settings sheet or danmaku; it reports gesture events through
// callbacks and the view model acts on them.
//
// VOD ONLY (rule 3): long-press 2x speed exists on VOD because a
// VOD file can be sped up; live is real-time and cannot be sped
// up, so the long-press path is gated on `isVod` and does nothing
// for live. The same file is reused by the live room in S4 with
// `isVod: false` — the gate is the enforcement, not a comment.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation
import SwiftUI
import UIKit

// MARK: - Config + pure math

/// Gesture constants (Flutter `vod_features.dart` parity: double
/// tap seeks 10 s; long-press 2x engages after a short hold so a
/// normal tap never triggers it).
enum VodGestureConfig {
    /// Double-tap seeks this many seconds (left = back, right = forward).
    static let doubleTapSeekSeconds: Double = 10
    /// Long-press must be held this long before 2x engages.
    static let longPressMinimumDuration: Double = 0.5
    /// Speed while long-pressing (VOD only).
    static let longPressSpeed: Double = 2.0
    /// Horizontal third of the screen: taps in the left third seek
    /// back, right third seek forward, middle toggles controls.
    static let sideTapFraction: CGFloat = 1.0 / 3.0
}

/// Pure gesture math, so tests can drive it without a view.
/// `seekDelta` is the signed seek for a double-tap at `x` in a
/// view of `width`: left third -10 s, right third +10 s, middle 0
/// (middle double-tap is not a seek — it falls through to the
/// single-tap control toggle). `longPressSpeed` is 2.0 only when
/// the press is held AND the player is VOD; anything else is nil
/// (no speed change).
enum VodGestureMath {
    static func seekDelta(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        if x < width * VodGestureConfig.sideTapFraction {
            return -VodGestureConfig.doubleTapSeekSeconds
        }
        if x > width * (1 - VodGestureConfig.sideTapFraction) {
            return VodGestureConfig.doubleTapSeekSeconds
        }
        return 0
    }

    static func longPressSpeed(isPressing: Bool, isVod: Bool) -> Double? {
        guard isPressing, isVod else { return nil }
        return VodGestureConfig.longPressSpeed
    }
}

// MARK: - Gesture state

/// Mutable gesture state, owned by the player page (via the view
/// model). The view drives it from SwiftUI gestures; the view
/// model subscribes to the callbacks. No driver reference here.
final class VodGestureState: ObservableObject {
    /// Long-press is currently held (2x active when VOD).
    @Published private(set) var isLongPressSpeeding = false
    /// Last double-tap side, for the seek-direction flash in the UI.
    @Published private(set) var lastDoubleTapDelta: Double = 0

    /// Whether this player is VOD. Set by the page (always true in
    /// S3; the live room in S4 sets false so long-press 2x is dead
    /// there). The gate lives here, not in the view.
    var isVod: Bool = true

    /// Fired when long-press 2x engages / releases (true = 2x on).
    var onLongPressSpeedChanged: ((Bool) -> Void)?
    /// Fired on double-tap with the signed seek seconds.
    var onDoubleTapSeek: ((Double) -> Void)?
    /// Fired on a single tap (toggle controls).
    var onSingleTap: (() -> Void)?

    /// Called by the long-press gesture when the press starts.
    /// VOD only: a live player ignores the press entirely.
    func longPressBegan() {
        guard isVod, !isLongPressSpeeding else { return }
        isLongPressSpeeding = true
        onLongPressSpeedChanged?(true)
    }

    /// Called by the long-press gesture when the press ends (or is
    /// cancelled). Always restores normal speed, even if the press
    /// never engaged (no-op then).
    func longPressEnded() {
        guard isLongPressSpeeding else { return }
        isLongPressSpeeding = false
        onLongPressSpeedChanged?(false)
    }

    /// Called by the double-tap gesture at `x` in a view of
    /// `width`. Middle double-taps are not seeks.
    func doubleTapped(atX x: CGFloat, width: CGFloat) {
        let delta = VodGestureMath.seekDelta(x: x, width: width)
        guard delta != 0 else { return }
        lastDoubleTapDelta = delta
        onDoubleTapSeek?(delta)
    }

    /// Called by the single-tap gesture.
    func singleTapped() {
        onSingleTap?()
    }
}

// MARK: - UIKit wiring
//
// SwiftUI's `onTapGesture(count:)` cannot report WHERE a
// double-tap landed (needed for left = back / right = forward),
// and a single-tap handler on the same view can also fire on a
// double-tap. So the overlay below uses UIKit recognisers: the
// single-tap requires the double-tap to fail, the double-tap
// reports its location, and the long-press reports press/release.
// All decisions (VOD gate, seek amount) still live in the state
// / math above — the recognisers only report raw gestures.

/// Transparent overlay hosting the VOD gesture recognisers. The
/// page puts it over the video area only (never over the progress
/// bar — scrubbing must never trigger a long-press 2x).
struct VodGestureOverlayView: UIViewRepresentable {
    var state: VodGestureState

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        long.minimumPressDuration = VodGestureConfig.longPressMinimumDuration
        long.allowableMovement = 20
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(long)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    final class Coordinator: NSObject {
        let state: VodGestureState

        init(state: VodGestureState) {
            self.state = state
        }

        @objc func singleTap(_ recogniser: UITapGestureRecognizer) {
            guard recogniser.state == .ended else { return }
            state.singleTapped()
        }

        @objc func doubleTap(_ recogniser: UITapGestureRecognizer) {
            guard recogniser.state == .ended,
                  let view = recogniser.view else { return }
            let location = recogniser.location(in: view)
            state.doubleTapped(atX: location.x, width: view.bounds.width)
        }

        @objc func longPress(_ recogniser: UILongPressGestureRecognizer) {
            switch recogniser.state {
            case .began:
                state.longPressBegan()
            case .ended, .cancelled, .failed:
                state.longPressEnded()
            default:
                break
            }
        }
    }
}

extension View {
    /// Attach the VOD gesture layer over the video area.
    func vodGestures(_ state: VodGestureState) -> some View {
        overlay(VodGestureOverlayView(state: state))
    }
}
