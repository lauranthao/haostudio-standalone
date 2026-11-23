// HaoSwipeActions — iOS-style swipe actions for list rows (b30).
//
// iOS Mail / Music: swipe a row left, action buttons slide in from
// the right (fixed width, pinned to the trailing edge); release past
// halfway and the row settles open; swipe all the way and the
// destructive action fires immediately; tapping the row while open
// closes it instead of activating it; opening one row closes any
// other open row. No `flutter_slidable` dependency — the behaviour
// is small enough to own, and the look (button size, colours,
// spring) stays in the app's hands.
//
// Actions are laid out left-to-right as given; put the destructive
// action LAST — a full swipe fires the last action (iOS convention:
// the rightmost button is the destructive one, e.g. [更多, 删除]).
// Never use Material `Dismissible` for these rows: it deletes on a
// fling with no buttons and no undo.

import 'package:flutter/material.dart';

import '../core/theme/haptics.dart';

class HaoSwipeAction {
  const HaoSwipeAction({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;
  final IconData? icon;
}

class HaoSwipeActions extends StatefulWidget {
  const HaoSwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.actionWidth = 76,
  }) : assert(actions.length > 0, 'need at least one action');

  final Widget child;
  final List<HaoSwipeAction> actions;

  /// Width of one action button (iOS uses ~70-80pt).
  final double actionWidth;

  @override
  State<HaoSwipeActions> createState() => _HaoSwipeActionsState();
}

class _HaoSwipeActionsState extends State<HaoSwipeActions>
    with SingleTickerProviderStateMixin {
  /// Pixels the row is slid left (0 = closed).
  var _offset = 0.0;

  /// The one row currently settled open anywhere in the app.
  static _HaoSwipeActionsState? _openRow;

  late final AnimationController _settleController;
  Animation<double>? _settle;

  double get _actionsWidth => widget.actionWidth * widget.actions.length;

  bool get _isOpen => _offset < -8;

  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        final settle = _settle;
        if (settle != null) setState(() => _offset = settle.value);
      });
  }

  @override
  void dispose() {
    if (_openRow == this) _openRow = null;
    _settleController.dispose();
    super.dispose();
  }

  void _animateOffsetTo(double target) {
    _settle = Tween<double>(begin: _offset, end: target).animate(
      CurvedAnimation(parent: _settleController, curve: Curves.easeOut),
    );
    _settleController
      ..reset()
      ..forward();
  }

  void _close() {
    if (_openRow == this) _openRow = null;
    _animateOffsetTo(0);
  }

  void _settleOpen() {
    _openRow?._close();
    _openRow = this;
    HaoHaptics.select();
    _animateOffsetTo(-_actionsWidth);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      // Only leftward; clamp the over-drag so a full swipe needs a
      // deliberate fling past the buttons.
      _offset = (_offset + details.delta.dx).clamp(
        -_actionsWidth * 1.6,
        0.0,
      );
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_offset <= -_actionsWidth - 40) {
      // Full swipe: fire the destructive (last) action, close.
      final action = widget.actions.last;
      _close();
      action.onTap();
      return;
    }
    if (_offset <= -_actionsWidth * 0.4) {
      _settleOpen();
    } else {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: Stack(
            children: [
              // Action buttons, pinned to the trailing edge, revealed
              // as the row slides left. They are ONLY mounted while
              // the row is open or being dragged: at rest (offset 0)
              // the row sits on top of them, but the row is glass —
              // translucent — so the grey/red buttons bleed through
              // the row's right edge on every row (b30, liked list).
              // Mounting them only while offset != 0 leaves nothing
              // behind the glass at rest.
              if (_offset != 0)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: _actionsWidth,
                  child: Row(
                    children: [
                      for (final action in widget.actions)
                        SizedBox(
                          width: widget.actionWidth,
                          height: double.infinity,
                          child: _SwipeActionButton(
                            action: action,
                            onTap: () {
                              _close();
                              action.onTap();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              Transform.translate(
                offset: Offset(_offset, 0),
                child: widget.child,
              ),
              // While open, taps on the row close it instead of
              // activating the row (iOS behaviour). The barrier
              // covers exactly the row's visible width.
              if (_isOpen)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: (width + _offset).clamp(0.0, width),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SwipeActionButton extends StatefulWidget {
  const _SwipeActionButton({required this.action, required this.onTap});

  final HaoSwipeAction action;
  final VoidCallback onTap;

  @override
  State<_SwipeActionButton> createState() => _SwipeActionButtonState();
}

class _SwipeActionButtonState extends State<_SwipeActionButton> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        HaoHaptics.tap();
        widget.onTap();
      },
      child: AnimatedOpacity(
        opacity: _pressed ? 0.6 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          color: action.color,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (action.icon != null) ...[
                Icon(action.icon, color: Colors.white, size: 20),
                const SizedBox(height: 2),
              ],
              Text(
                action.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
