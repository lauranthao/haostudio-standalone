// HaoSlider — the app's one slider component (build-29 adoption).
//
// iOS: the real `UISlider` via glassy_ui_ios `GlassSlider` (tint =
// the call site's accent). Other platforms / tests: the Material
// `Slider` verbatim — same value, min/max, divisions, label,
// activeColor and callbacks — so behaviour is identical off-iOS.
//
// A null [onChanged] (a disabled row, e.g. danmaku stroke width
// with stroke off) renders the disabled Material Slider directly:
// `GlassSlider` requires a non-null onChanged, and a no-op would
// wrongly stay draggable on iOS.
import 'package:flutter/material.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart' as glassy;

class HaoSlider extends StatelessWidget {
  const HaoSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.onChangeStart,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Called when a scrub starts. The Material fallback gets the
  /// real `onChangeStart`; the native `UISlider` has no such
  /// callback, so a pointer-down on the slider fires it instead —
  /// a tap-to-seek is a scrub start too, so the semantics match
  /// (used by the video progress bar to cancel the hide timer
  /// before the drag can unmount the control bar).
  final ValueChanged<double>? onChangeStart;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final onChangeStart = this.onChangeStart;
    final fallback = Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: activeColor,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
      onChangeStart: onChangeStart,
    );
    if (onChanged == null) return fallback;
    final native = glassy.GlassSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
      style: glassy.NativeStyle(tintColor: activeColor),
      fallback: fallback,
    );
    if (onChangeStart == null) return native;
    return Listener(
      onPointerDown: (_) => onChangeStart(value),
      child: native,
    );
  }
}
