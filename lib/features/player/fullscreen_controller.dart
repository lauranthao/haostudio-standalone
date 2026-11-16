// Fullscreen controller (fix 2).
//
// The live room is an ordinary in-app page — NOT a fullscreen modal and
// NOT a separate full-screen page. ONLY the [ ] fullscreen button (and the
// equivalent fullscreen gesture) takes the room to landscape fullscreen —
// WHOLE-APP rotation (tab bar and content included, per the standing
// landscape rule), driven as app state through the [ ] action, not by the
// video widget alone. Exiting fullscreen returns to the same portrait
// room, same stream, without re-fetching the URL or restarting playback.
//
// Room entry is ALWAYS portrait by construction — there is no flag
// to request landscape on entry; the [ ] action rotates the
// existing player in place instead of presenting a new page, and
// there is no re-open path to landscape. There is no other path to
// landscape for a live room: no auto-rotate on entry, no rotate on
// device tilt, no rotate when playback starts.
//
// VOD is the opposite (tap-play goes DIRECTLY to landscape fullscreen)
// and must not share this entry flag default.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

class FullscreenController extends GetxController {
  final RxBool isFullscreen = false.obs;

  /// Enter landscape fullscreen (the [ ] action).
  ///
  /// Pure Live `WindowService.landScape()` verbatim: on mobile it is ONLY
  /// `SystemChrome.setPreferredOrientations` — no native force-rotation,
  /// no MethodChannel. (A native `UIDevice.setValue` plugin was added
  /// on a misread of chen's report and reverted: chen confirmed the []
  /// button DOES rotate; the fault was the landscape DISPLAY, not the
  /// rotation. Pure Live has no such plugin.) The immersive switch is
  /// the mobile half of Pure Live's fullscreen presentation driver.
  Future<void> enterFullscreen() async {
    isFullscreen.value = true;
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// Exit back to the same portrait room, same stream.
  ///
  /// Pure Live `WindowService.verticalScreen()` verbatim: an explicit
  /// `[portraitUp]` mask — iOS does NOT rotate an already-landscape UI
  /// back on "follow system" (empty array), so the portrait mask must
  /// be set explicitly (Pure Live `doExitFullScreen` comment).
  Future<void> exitFullscreen() async {
    isFullscreen.value = false;
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> toggleFullscreen() async {
    if (isFullscreen.value) {
      await exitFullscreen();
    } else {
      await enterFullscreen();
    }
  }

  @override
  void onClose() {
    // Never leave the app stuck in landscape when the room is gone.
    if (isFullscreen.value) {
      unawaited(exitFullscreen());
    }
    super.onClose();
  }
}
