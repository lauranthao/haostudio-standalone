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
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final fallback = Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: activeColor,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    if (onChanged == null) return fallback;
    return glassy.GlassSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
      style: glassy.NativeStyle(tintColor: activeColor),
      fallback: fallback,
    );
  }
}
