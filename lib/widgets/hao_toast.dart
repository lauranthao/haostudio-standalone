// HaoToast — top slide-down banner (N-3, D-5版式).
//
// iOS has no bottom snackbar, so every former `Get.snackbar` call now
// shows this instead: an iOS-notification-style banner under the
// status bar — horizontal margin 12, radius 14, glass card from the
// theme variables, leading icon (info / check / warning), title +
// optional message, auto-dismiss 2.5s, tap or swipe-up to dismiss.
//
// No BuildContext needed at call sites: the overlay is taken from
// Get's navigator key (the app runs under GetMaterialApp), exactly
// like the old `Get.snackbar` calls. When there is no overlay (unit
// tests without an app, or no binding yet) the call is a silent no-op
// — callers must never depend on the banner for state; the state
// change that triggered the toast is the source of truth.
//
// Kind is inferred from the title when not given, so the mechanical
// `Get.snackbar(title, message)` → `HaoToast.show(title, message: message)`
// replacement keeps the icon honest: titles with 失败 / 不能 / 至少
// read as warnings, titles starting with 已 or containing 成功 read
// as success, everything else is info. Call sites that need a
// different icon pass [kind] explicitly.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../core/theme/glass.dart';
import '../core/theme/hao_themes.dart';

/// Icon shown at the leading edge of the banner.
enum HaoToastKind {
  /// Neutral notice (default).
  info,

  /// Completed action — check mark.
  success,

  /// Failed / blocked action — warning mark in the app's single red
  /// (liveRed: red only where it truly means something, and a failure
  /// is one of those places).
  warning,
}

/// One inline action button inside the banner (e.g. 重试 / 下一首).
/// The playback notice is the only caller that needs actions; every
/// other call site passes none.
class HaoToastAction {
  const HaoToastAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}

class HaoToast {
  HaoToast._();

  /// Default auto-dismiss (D-5): 2.5s. Callers that passed an explicit
  /// `duration` to Get.snackbar keep that value instead.
  static const Duration defaultDuration = Duration(milliseconds: 2500);

  static OverlayEntry? _current;
  static Timer? _timer;

  /// Show a banner. Replaces any banner currently on screen (same as
  /// Get.snackbar's replace-current behaviour). [context] is only
  /// needed when the caller has no GetMaterialApp above it (tests);
  /// in the app the overlay is taken from Get's navigator key.
  static void show(
    String title, {
    String? message,
    Duration duration = defaultDuration,
    HaoToastKind? kind,
    List<HaoToastAction> actions = const [],
    BuildContext? context,
  }) {
    try {
      final OverlayState? overlay = context != null
          ? Overlay.of(context)
          : Get.key.currentState?.overlay;
      if (overlay == null) return;
      dismiss();
      final entry = OverlayEntry(
        builder: (ctx) => _HaoToastBanner(
          title: title,
          message: message,
          kind: kind ?? _inferKind(title),
          actions: actions,
          onDismiss: dismiss,
        ),
      );
      _current = entry;
      overlay.insert(entry);
      _timer = Timer(duration, dismiss);
    } catch (_) {
      // No binding / no overlay (unit tests): the recorded state is
      // enough, never throw into the caller.
    }
  }

  /// Dismiss the banner currently on screen, if any.
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _current?.remove();
    _current = null;
  }

  /// Test-only: whether a banner is currently inserted.
  @visibleForTesting
  static bool get isShowing => _current != null;

  static HaoToastKind _inferKind(String title) {
    if (title.contains('失败') ||
        title.contains('不能') ||
        title.contains('至少')) {
      return HaoToastKind.warning;
    }
    if (title.startsWith('已') || title.contains('成功')) {
      return HaoToastKind.success;
    }
    return HaoToastKind.info;
  }
}

class _HaoToastBanner extends StatefulWidget {
  const _HaoToastBanner({
    required this.title,
    required this.message,
    required this.kind,
    required this.actions,
    required this.onDismiss,
  });

  final String title;
  final String? message;
  final HaoToastKind kind;
  final List<HaoToastAction> actions;
  final VoidCallback onDismiss;

  @override
  State<_HaoToastBanner> createState() => _HaoToastBannerState();
}

class _HaoToastBannerState extends State<_HaoToastBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // iOS banner slides down from the status bar and settles; easeOut
    // (no overshoot — a banner is not a sheet).
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.ofOrDefault(context);
    final media = MediaQuery.of(context);
    final IconData icon;
    final Color iconColor;
    switch (widget.kind) {
      case HaoToastKind.success:
        icon = Icons.check_circle_outline;
        iconColor = theme.accent;
      case HaoToastKind.warning:
        icon = Icons.warning_amber_outlined;
        iconColor = theme.liveRed;
      case HaoToastKind.info:
        icon = Icons.info_outline;
        iconColor = theme.accent;
    }
    final message = widget.message;
    return Positioned(
      // Below the status bar, horizontal margin 12 (D-5).
      top: media.padding.top + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Dismissible(
            key: const ValueKey('hao-toast'),
            direction: DismissDirection.up,
            onDismissed: (_) => widget.onDismiss(),
            child: GestureDetector(
              onTap: widget.onDismiss,
              child: GlassCard(
                radius: 14,
                shadow: GlassShadow.panel,
                quality: GlassCardQuality.premium,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: iconColor, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              color: theme.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (message != null && message.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              message,
                              style: TextStyle(
                                color: theme.textSecondary,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ],
                          if (widget.actions.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final action in widget.actions)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: GestureDetector(
                                      onTap: () {
                                        widget.onDismiss();
                                        action.onTap();
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: theme.accentSoft,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          action.label,
                                          style: TextStyle(
                                            color: theme.accent,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
