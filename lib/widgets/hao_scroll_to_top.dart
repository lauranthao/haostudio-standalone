// Scroll-to-top registry (b30 iOS interactions).
//
// iOS scrolls the current list to the top on two gestures:
//  - tapping the status bar,
//  - tapping the already-selected bottom tab.
// Flutter has no built-in status-bar-tap signal, so the tab pages
// register their main list controller here under a tab key, and the
// tap zones (AppShell's status-bar strip, HaoNavBar's strip) call
// [scrollToTop] for the right key. A controller is unregistered on
// dispose, and `scrollToTop` no-ops when the key is unknown or the
// controller has no clients — never throws into a gesture handler.

import 'package:flutter/material.dart';

class HaoScrollToTop {
  HaoScrollToTop._();

  /// Tab keys (AppShell's four tabs, in tab order).
  static const String videoTab = 'tab:video';
  static const String liveTab = 'tab:live';
  static const String musicTab = 'tab:music';
  static const String settingsTab = 'tab:settings';

  static const List<String> tabKeys = [
    videoTab,
    liveTab,
    musicTab,
    settingsTab,
  ];

  static final Map<String, ScrollController> _controllers = {};

  static void register(String key, ScrollController controller) {
    _controllers[key] = controller;
  }

  /// Only removes the entry when it still points at [controller]
  /// (a re-registered page must not be cleared by a stale dispose).
  static void unregister(String key, ScrollController controller) {
    if (_controllers[key] == controller) _controllers.remove(key);
  }

  @visibleForTesting
  static bool isRegistered(String key) => _controllers.containsKey(key);

  /// Animates the registered list to the top. Returns false when
  /// there is nothing to scroll (unknown key / no clients).
  static bool scrollToTop(String key) {
    final controller = _controllers[key];
    if (controller == null || !controller.hasClients) return false;
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
    return true;
  }
}
