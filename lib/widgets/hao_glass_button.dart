// HaoGlassButton / HaoGlassIconButton — app wrappers over
// glassy_ui_ios buttons (build-29 adoption, direct swap).
//
// iOS: a real UIButton (GlassButton / GlassIconButton) — native press
// animation, tint and haptics. Everywhere else: the original Material
// button passed as [fallback] / built from [fallbackIcon], so the
// appearance and behaviour are unchanged off-iOS. [onPressed] null
// renders the (disabled) fallback on every platform: GlassButton has
// no disabled state, so a disabled button must never reach the native
// view.
//
// Icon buttons in scrolling list rows are deliberately NOT swapped
// through this wrapper: each native view is a UiKitView, and a row
// already carries one (HaoNativeSwitch) — two more per row would cost
// scroll smoothness. Row trailing actions keep IconButton (their
// CupertinoIcons already draw SF Symbols); AppBar and standalone
// actions use this wrapper.

import 'package:flutter/material.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart';

/// A prominent (filled) button: iOS renders a native glass button,
/// other platforms render [fallback] (the original FilledButton).
class HaoGlassButton extends StatelessWidget {
  const HaoGlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.iconSymbol,
    this.prominent = true,
    this.height = 50,
    this.style,
    required this.fallback,
  });

  /// Button text.
  final String label;

  /// Null = disabled: the fallback renders, the native view is never
  /// built (GlassButton has no disabled state).
  final VoidCallback? onPressed;

  /// Optional SF Symbol shown before the label
  /// (e.g. 'square.and.arrow.up' for an upload button).
  final String? iconSymbol;

  /// Filled (`.glassProminent`) instead of clear glass.
  final bool prominent;

  /// Native view height; the fallback keeps its own height.
  final double height;

  /// Appearance (tint). Defaults to the app theme.
  final NativeStyle? style;

  /// The original Material button, rendered off-iOS and whenever the
  /// button is disabled.
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final onPressed = this.onPressed;
    if (onPressed == null) return fallback;
    return GlassButton(
      label: label,
      icon: iconSymbol == null ? null : NativeImage.symbol(iconSymbol!),
      prominent: prominent,
      height: height,
      style: style,
      onPressed: onPressed,
      fallback: fallback,
    );
  }
}

/// A circular icon button: iOS renders a native glass icon button,
/// other platforms render an IconButton built from [fallbackIcon].
/// Only for AppBar / standalone actions — never inside scrolling list
/// rows (see the file header).
class HaoGlassIconButton extends StatelessWidget {
  const HaoGlassIconButton({
    super.key,
    required this.symbol,
    required this.fallbackIcon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 20,
    this.color,
    this.style,
  });

  /// SF Symbol name rendered on iOS.
  final String symbol;

  /// Material icon rendered off-iOS.
  final IconData fallbackIcon;

  /// Null = disabled: the fallback renders, the native view is never
  /// built.
  final VoidCallback? onPressed;

  /// VoiceOver label on iOS, tooltip off-iOS.
  final String? tooltip;

  /// Point size of the icon (both paths).
  final double iconSize;

  /// Icon colour off-iOS (iOS tints from the theme).
  final Color? color;

  /// Appearance. Defaults to the app theme.
  final NativeStyle? style;

  @override
  Widget build(BuildContext context) {
    final onPressed = this.onPressed;
    final fallback = IconButton(
      icon: Icon(fallbackIcon, size: iconSize),
      color: color,
      tooltip: tooltip,
      onPressed: onPressed,
    );
    if (onPressed == null) return fallback;
    return GlassIconButton(
      icon: NativeImage.symbol(symbol),
      semanticLabel: tooltip,
      iconSize: iconSize,
      onPressed: onPressed,
      style: style,
      fallback: fallback,
    );
  }
}
