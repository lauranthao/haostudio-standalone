// Screen brightness — the same packages Pure Live uses
// (screen_brightness_platform_interface + screen_brightness_ios).
// Pure Live API: ScreenBrightnessPlatform.instance.application /
// setApplicationScreenBrightness. Best-effort: any failure leaves
// the brightness unchanged and the caller falls back to 0.5.

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
}
