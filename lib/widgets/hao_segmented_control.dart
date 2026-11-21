// HaoSegmentedControl — iOS UISegmentedControl (N-9).
//
// Replaces the 6 Material SegmentedButtons: the selected segment is
// a rounded pill that SLIDES to the tapped segment on the settle
// spring (HaoSettleSpringCurve, same spring as the player expand),
// instead of the background colour just flipping. Segment labels
// are 13pt Semibold; selected label is the theme accent, the rest
// secondary. Tapping a segment fires HaoHaptics.select() (N-13 —
// the control owns the haptic, so no call site can forget it).
//
// Colours come from HaoTheme only (all 4 themes x light/dark); no
// purple anywhere; the pill is the accent wash, never red.

import 'package:flutter/material.dart';

import '../core/theme/hao_radius.dart';
import '../core/theme/hao_settle_spring.dart';
import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';

class HaoSegment<T> {
  const HaoSegment({required this.value, required this.label});

  final T value;
  final String label;
}

class HaoSegmentedControl<T> extends StatelessWidget {
  const HaoSegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  }) : assert(segments.length > 1, 'need at least 2 segments');

  final List<HaoSegment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    var selectedIndex = segments.indexWhere((s) => s.value == value);
    if (selectedIndex < 0) selectedIndex = 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        // All 6 call sites are width-bounded (ListTile trailing,
        // Expanded, full-width Padding); the fallback only guards
        // against an unbounded test harness.
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 300.0;
        final segmentWidth = width / segments.length;
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: theme.hairline),
            borderRadius: BorderRadius.circular(HaoRadius.large),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 350),
                curve: const HaoSettleSpringCurve(),
                left: selectedIndex * segmentWidth + 2,
                top: 2,
                bottom: 2,
                width: segmentWidth - 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final segment in segments)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (segment.value != value) {
                            HaoHaptics.select();
                            onChanged(segment.value);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          alignment: Alignment.center,
                          child: Text(
                            segment.label,
                            style: TextStyle(
                              color: segment.value == value
                                  ? theme.accent
                                  : theme.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
