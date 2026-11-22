// HaoInsetGroupedSection — iOS inset grouped list section (build-29
// adoption).
//
// The iOS look chen asked for (“都要原生效果”): 10pt corner radius,
// solid system-grouped row colour (theme.surfaceSolid), 0.5pt
// hairline border, NO shadow, NO frosted blur. A section is a solid
// slab on the scaffold — readable at glass 0% and 100% alike,
// because it paints no glass of its own.
//
// The page's own 16pt side padding IS the section inset (the
// settings ListView already pads 16); this widget adds no horizontal
// margin of its own, or the inset would double to 32.
//
// Drop-in replacement for HaoGlassCard where the child is a list of
// rows: same {child, padding, margin} API. `quality` is gone —
// sections are always solid, that is the iOS look.
import 'package:flutter/material.dart';

import '../core/theme/hao_themes.dart';

class HaoInsetGroupedSection extends StatelessWidget {
  const HaoInsetGroupedSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(4),
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          color: theme.surfaceSolid,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.hairline, width: 0.5),
        ),
        padding: padding,
        // Transparent Material inside the section: ListTile rows
        // paint their ink splashes on the nearest Material ancestor
        // — without this Flutter asserts ("ink splashes may be
        // invisible") and taps show no ripple. The Material is
        // transparent, so the section colour is untouched.
        child: Material(color: Colors.transparent, child: child),
      ),
    );
  }
}
