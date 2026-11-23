// HaoNavBar — the app's one top bar (b30 iOS interactions).
//
// build-29 shipped the native bottom bar / switches / dialogs, but
// every pushed page still used Material `AppBar` (38 sites): Android
// back arrow, Material title, Material ripple on the action buttons.
// This replaces all of them with `CupertinoNavigationBar` — the real
// iOS nav bar: back chevron (swipe-back already works via
// CupertinoPageRoute), centred 17pt semibold title, frosted
// background (the nav bar blurs behind `theme.surface`, same optics
// as `HaoAppBarGlass`, so the old `flexibleSpace: HaoAppBarGlass`
// is dropped at the call sites), hairline bottom border.
//
// - [largeTitle]: renders the iOS 34pt bold large title row under
//   the 44pt bar (CupertinoNavigationBar's `largeTitle`).
// - [scrollController]: when set, the status-bar strip (the top
//   safe-area inset, which is part of the nav bar) becomes a tap
//   zone that scrolls the page's list to the top — the iOS
//   status-bar-tap gesture. Pages without a long list omit it.
// - Action buttons go through [HaoNavBarButton] /
//   [HaoNavBarTextButton] (same file): 44pt hit area, opacity press
//   (no Material ripple), `HaoHaptics.tap()` on tap — the iOS
//   press feedback the old `IconButton`s never had.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../core/theme/hao_themes.dart';
import '../core/theme/haptics.dart';

class HaoNavBar extends StatelessWidget implements PreferredSizeWidget {
  const HaoNavBar({
    super.key,
    required this.title,
    this.largeTitle = false,
    this.leading,
    this.actions,
    this.trailing,
    this.automaticallyImplyLeading = true,
    this.scrollController,
    this.backgroundColor,
  });

  /// Title text (middle, 17pt semibold; large title, 34pt bold).
  final String title;

  /// iOS large-title row under the 44pt bar.
  final bool largeTitle;

  /// Custom leading (e.g. a close button). Null = automatic back
  /// chevron when the route can pop.
  final Widget? leading;

  /// Trailing action buttons (rendered as a tight Row).
  final List<Widget>? actions;

  /// Single trailing widget (takes precedence over [actions]).
  final Widget? trailing;

  final bool automaticallyImplyLeading;

  /// Status-bar-tap scroll target. Null = no tap zone.
  final ScrollController? scrollController;

  /// Null = `theme.surface` (low-alpha, frosted by the nav bar).
  final Color? backgroundColor;

  static const double _barHeight = 44.0;

  /// Cupertino large-title extension (52pt, same as the framework's
  /// `_kNavBarLargeTitleHeightExtension`).
  static const double _largeTitleHeight = 52.0;

  @override
  Size get preferredSize =>
      Size.fromHeight(_barHeight + (largeTitle ? _largeTitleHeight : 0));

  /// Trailing widget for the Cupertino bar. A single action is passed
  /// through unwrapped: wrapping it in a Row makes the nav-bar hero
  /// flight measure a fractional content width (text button) and lay
  /// the flight Row out 0.82px too narrow — a RenderFlex overflow on
  /// every push of a page with a text trailing (Emby 备用线路).
  Widget? get _trailing {
    if (trailing != null) return trailing;
    final a = actions;
    if (a == null || a.isEmpty) return null;
    if (a.length == 1) return a.single;
    return Row(mainAxisSize: MainAxisSize.min, children: a);
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final titleStyle = TextStyle(
      color: theme.textPrimary,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      shadows: HaoTheme.legibilityShadows(context),
    );
    final navBar = largeTitle
        // Large title lives on the named constructor only
        // (CupertinoNavigationBar.large); the base constructor
        // forces largeTitle null.
        ? CupertinoNavigationBar.large(
            largeTitle: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle.copyWith(
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
            leading: leading,
            trailing: _trailing,
            automaticallyImplyLeading: automaticallyImplyLeading,
            backgroundColor: backgroundColor ?? theme.surface,
            border: Border(
              bottom: BorderSide(color: theme.hairline, width: 0.5),
            ),
          )
        : CupertinoNavigationBar(
            middle: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
            leading: leading,
            trailing: _trailing,
            automaticallyImplyLeading: automaticallyImplyLeading,
            backgroundColor: backgroundColor ?? theme.surface,
            border: Border(
              bottom: BorderSide(color: theme.hairline, width: 0.5),
            ),
          );
    final sc = scrollController;
    if (sc == null) return navBar;
    final topPadding = MediaQuery.paddingOf(context).top;
    if (topPadding <= 0) return navBar;
    return Stack(
      children: [
        navBar,
        // Status-bar tap zone: the strip above the 44pt row. It
        // holds no nav-bar controls, so an opaque detector here
        // cannot steal a button tap — it only catches taps on the
        // status bar itself, exactly like iOS.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topPadding,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (sc.hasClients) {
                sc.animateTo(
                  0,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOut,
                );
              }
            },
          ),
        ),
      ],
    );
  }
}

/// One nav-bar icon button: 44pt hit area, iOS opacity press (no
/// Material ripple), `HaoHaptics.tap()` on tap. Disabled
/// (`onPressed: null`) dims to 0.35 and takes no taps.
class HaoNavBarButton extends StatefulWidget {
  const HaoNavBarButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback? onPressed;

  /// Accessibility label (long-press tooltip), the same text the
  /// old Material IconButton carried — the iOS conversion dropped
  /// it on 15 buttons (live room switch, clear-history, upload,
  /// ...); a nav button with no label is invisible to VoiceOver
  /// and to tooltip-driven tests.
  final String? tooltip;

  @override
  State<HaoNavBarButton> createState() => _HaoNavBarButtonState();
}

class _HaoNavBarButtonState extends State<HaoNavBarButton> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              HaoHaptics.tap();
              widget.onPressed!();
            }
          : null,
      child: AnimatedOpacity(
        opacity: !enabled ? 0.35 : (_pressed ? 0.55 : 1.0),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: widget.child),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// Floating back button for cover-hero pages (video / Emby detail):
/// a dark circle with a white chevron, pinned top-left over the
/// cover. The hero's own back button used to live inside the
/// scrolling cover — once the user scrolled down, the only exit was
/// the edge-swipe gesture, and the load-failed card had no exit at
/// all. This is a [Positioned] for a page-level [Stack] over the
/// body, so the exit stays visible in every state (loading,
/// loaded, failed) and at any scroll offset. Same optics as the old
/// hero button (0x66000000 circle, white chevron), so the top of
/// the page looks unchanged.
class HaoCoverBackButton extends StatefulWidget {
  const HaoCoverBackButton({super.key, this.onPressed});

  /// Null = pop the current route.
  final VoidCallback? onPressed;

  @override
  State<HaoCoverBackButton> createState() => _HaoCoverBackButtonState();
}

class _HaoCoverBackButtonState extends State<HaoCoverBackButton> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          HaoHaptics.tap();
          if (widget.onPressed != null) {
            widget.onPressed!();
          } else {
            Navigator.of(context).pop();
          }
        },
        child: AnimatedOpacity(
          opacity: _pressed ? 0.55 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0x66000000),
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.back,
              shadows: HaoTheme.legibilityShadows(context),
              color: CupertinoColors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// One nav-bar text button ('完成'): accent 17pt text, iOS opacity
/// press + tap haptic, same behaviour as [HaoNavBarButton].
class HaoNavBarTextButton extends StatefulWidget {
  const HaoNavBarTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  State<HaoNavBarTextButton> createState() => _HaoNavBarTextButtonState();
}

class _HaoNavBarTextButtonState extends State<HaoNavBarTextButton> {
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final enabled = widget.onPressed != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled
          ? () {
              HaoHaptics.tap();
              widget.onPressed!();
            }
          : null,
      child: AnimatedOpacity(
        opacity: !enabled ? 0.35 : (_pressed ? 0.55 : 1.0),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(
            widget.label,
            style: TextStyle(
              color: theme.accent,
              fontSize: 17,
              shadows: HaoTheme.legibilityShadows(context),
            ),
          ),
        ),
      ),
    );
  }
}
