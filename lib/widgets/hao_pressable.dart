// HaoPressable — the app's pressable row/button (N-16).
//
// iOS has no Material ripple: pressing a row dims the whole row
// instead of spreading a wave. [HaoPressable] is a [GestureDetector]
// + [AnimatedOpacity]: content fades to [pressedOpacity] while the
// finger is down and back on release. Use it wherever an [InkWell]
// used to be; [ListTile] rows get the same treatment via the theme's
// NoSplash splash factory (see hao_themes.dart), so both paths dim
// instead of rippling.

import 'package:flutter/material.dart';

class HaoPressable extends StatefulWidget {
  const HaoPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.onLongPress,
    this.pressedOpacity = 0.6,
    this.borderRadius,
  });

  final VoidCallback? onTap;
  final Widget child;

  /// Long-press action (e.g. a song row opening its more menu).
  /// Press-dim still applies while the long-press is held.
  final VoidCallback? onLongPress;

  /// Content opacity while pressed (iOS dims the row; 0.6 reads as a
  /// press without washing the row out).
  final double pressedOpacity;

  final BorderRadius? borderRadius;

  @override
  State<HaoPressable> createState() => _HaoPressableState();
}

class _HaoPressableState extends State<HaoPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final child = AnimatedOpacity(
      opacity: _pressed ? widget.pressedOpacity : 1.0,
      duration: const Duration(milliseconds: 100),
      child: widget.child,
    );
    final radius = widget.borderRadius;
    // InkWell parity: the detector itself is hit over the whole box,
    // so presses on empty space inside a row (between the text and
    // the buttons) still reach onTap/onLongPress — deferToChild
    // dropped them (song quick menu regression, 1.1.6).
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: radius == null
          ? child
          : ClipRRect(borderRadius: radius, child: child),
    );
  }
}
