// showHaoSheet — the app's one bottom sheet (b30 iOS interactions).
//
// build-29 left 21 `showModalBottomSheet` call sites: Material slide
// animation, Material drag handle, Material barrier. This routes
// every sheet through `showCupertinoModalPopup` — the iOS modal
// animation + barrier tap to dismiss — with one addition the
// framework popup lacks: drag-to-dismiss. The drag recogniser lives
// on the handle zone only (the sheet's own scrollable content keeps
// its gestures); dragging the handle down past 100pt, or flicking it
// down fast, slides the sheet off and pops it, otherwise it springs
// back. The handle floats just above the sheet's top edge, the look
// the old Material `showDragHandle` already had.
//
// The sheet content keeps its own background (GlassSheetBackground /
// GlassContainer / solid Container) — the scaffold paints nothing
// behind it. Tall content is capped at 90% of the screen so it can
// never overflow on a short screen; the content's own scroll view
// handles the rest. Return values work exactly like before
// (quality / sleep / track-more sheets return their pick, or null
// on dismiss).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

Future<T?> showHaoSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? barrierColor,
  bool barrierDismissible = true,
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.35),
    barrierDismissible: barrierDismissible,
    builder: (sheetContext) =>
        _HaoSheetScaffold(child: builder(sheetContext)),
  );
}

/// Sheet chrome: floating grabber + drag-to-dismiss, around the
/// caller's content.
class _HaoSheetScaffold extends StatefulWidget {
  const _HaoSheetScaffold({required this.child});

  final Widget child;

  @override
  State<_HaoSheetScaffold> createState() => _HaoSheetScaffoldState();
}

class _HaoSheetScaffoldState extends State<_HaoSheetScaffold>
    with SingleTickerProviderStateMixin {
  /// Pixels dragged down from rest (0 = settled).
  var _dragOffset = 0.0;
  late final AnimationController _settleController;
  Animation<double>? _settle;

  /// Dismiss once the handle is dragged this far, or flicked faster
  /// than this (pt/s).
  static const double _dismissDistance = 100;
  static const double _dismissVelocity = 600;

  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        final settle = _settle;
        if (settle != null) setState(() => _dragOffset = settle.value);
      });
  }

  @override
  void dispose() {
    _settleController.dispose();
    super.dispose();
  }

  void _animateOffsetTo(double target, {VoidCallback? onDone}) {
    _settle = Tween<double>(begin: _dragOffset, end: target).animate(
      CurvedAnimation(parent: _settleController, curve: Curves.easeOut),
    );
    _settleController
      ..reset()
      ..forward().then((_) => onDone?.call());
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final height = MediaQuery.sizeOf(context).height;
    if (_dragOffset > _dismissDistance || velocity > _dismissVelocity) {
      // Slide off the bottom, then pop (no value — same as a
      // barrier-tap dismiss).
      _animateOffsetTo(
        height,
        onDone: () {
          if (mounted) Navigator.of(context).pop();
        },
      );
    } else {
      _animateOffsetTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Transform.translate(
      offset: Offset(0, _dragOffset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle zone: the only drag-to-dismiss target, so the
            // sheet's own scrollable content keeps its gestures.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                setState(() {
                  _dragOffset = (_dragOffset + details.delta.dy).clamp(
                    0.0,
                    double.infinity,
                  );
                });
              },
              onVerticalDragEnd: _onDragEnd,
              child: Container(
                height: 20,
                alignment: Alignment.center,
                // Transparent: the grabber floats above the sheet,
                // the look the old Material handle already had.
                color: Colors.transparent,
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.4)
                        : Colors.black.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            // No Flexible here: in a min-sized Column a flex child
            // would stretch short sheets to the 90% cap. The
            // ConstrainedBox caps tall content instead, and the
            // sheet's own scroll view handles the rest.
            widget.child,
          ],
        ),
      ),
    );
  }
}
