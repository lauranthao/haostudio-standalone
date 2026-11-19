// Screen brightness — the same packages Pure Live uses
// (screen_brightness_platform_interface + screen_brightness_ios).
// Pure Live API: ScreenBrightnessPlatform.instance.application /
// setApplicationScreenBrightness. Best-effort: any failure leaves
// the brightness unchanged and the caller falls back to 0.5.
//
// iOS has no per-app brightness: setApplicationScreenBrightness
// writes UIScreen.main.brightness (the DEVICE brightness) and the
// plugin remembers it as applicationScreenBrightness. With
// isAutoReset (default true) the plugin restores the system value
// while backgrounded but RE-APPLIES the remembered app value on
// return — so a player that sets brightness and never resets it
// keeps overriding whatever the user picked in Control Center, on
// every page, forever. reset() is the documented "user leaves the
// page that changed the brightness" call: it restores the system
// value and clears the remembered app value, so nothing is
// re-applied afterwards. Every page that calls setBrightness must
// call reset() on dispose AND on backgrounding (paused).

import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class ScreenBrightness {
  ScreenBrightness._();

  static Future<double> getBrightness() async {
    try {
      return (await ScreenBrightnessPlatform.instance.application)
          .clamp(0.0, 1.0);
    } catch (_) {}
    return 0.5;
  }

  static Future<void> setBrightness(double value) async {
    try {
      await ScreenBrightnessPlatform.instance
          .setApplicationScreenBrightness(value.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// Hand the brightness back to the system: restores the system
  /// brightness the user last set (e.g. in Control Center) and
  /// clears the remembered app brightness, so returning to the
  /// foreground does NOT re-apply a stale player value.
  /// Best-effort: never throws.
  static Future<void> reset() async {
    try {
      await ScreenBrightnessPlatform.instance
          .resetApplicationScreenBrightness();
    } catch (_) {}
  }
}
