import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../widgets/app_shell.dart';
import 'music_navigation.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';

/// The single shared route observer for the mini player overlay.
/// Created once in main.dart and handed to both GetMaterialApp
/// (`navigatorObservers`) and [MiniPlayerOverlay].
///
/// It tracks the route stack (push / pop / replace / remove) and
/// reports whether the top route is a music sub-page: a [PageRoute]
/// whose name is [musicSubPageRouteName]. Anything else on top — the
/// full player, the equalizer, video / live / settings pages, a
/// dialog or a bottom sheet (PopupRoutes) — hides the overlay.
///
/// The observer is generic over [Route] (not [PageRoute]) on purpose:
/// a `RouteObserver<PageRoute>` never hears about PopupRoutes, so a
/// bottom sheet opened over a music sub-page would leave the overlay
/// floating over the sheet. Observing all routes makes the sheet
/// itself the top route, which is not a music page, so the overlay
/// hides while the sheet is up and returns when it closes.
class MusicRouteObserver extends RouteObserver<Route<dynamic>> {
  /// Whether the top route is a music sub-page right now.
  final ValueNotifier<bool> isMusicSubPage = ValueNotifier(false);

  final List<Route<dynamic>> _stack = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _update();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _update();
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _stack.remove(oldRoute);
    if (newRoute != null) _stack.add(newRoute);
    _update();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _update();
    super.didRemove(route, previousRoute);
  }

  void _update() {
    final top = _stack.isEmpty ? null : _stack.last;
    isMusicSubPage.value =
        top is PageRoute && top.settings.name == musicSubPageRouteName;
  }
}

/// The one shared instance, created here so main.dart and the overlay
/// always use the same observer (and the same notifier).
final musicRouteObserver = MusicRouteObserver();

/// App-level mini player overlay, mounted above the root Navigator in
/// GetMaterialApp's `builder` (see main.dart).
///
/// Shows only when all three hold:
/// - the top route is a music sub-page ([MusicRouteObserver]);
/// - a song is loaded (the bar itself renders nothing without one);
/// - the keyboard is hidden (typing in search must not fight the bar).
///
/// The home page keeps its own embedded [MiniPlayerBar] — the overlay
/// is hidden there because the home route carries no music name.
/// Tapping the bar opens the full player with the expand animation
/// (see `player_expand_route.dart`); the full player route is
/// unnamed, so the overlay hides above it and returns when it closes.
/// The show/hide is a 250ms fade (AnimatedSwitcher), not a pop: on
/// close the bar fades back in over the content while the player
/// slides right (video frame 017), and on open it fades out as the
/// sheet expands over it.
class MiniPlayerOverlay extends StatelessWidget {
  const MiniPlayerOverlay({super.key, required this.observer});

  final MusicRouteObserver observer;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // Windows: the sidebar owns the left strip — the bar floats at
      // the bottom of the CONTENT area, not under the rail.
      left: Platform.isWindows ? AppShell.windowsSidebarWidth : 0,
      right: 0,
      // Above the home indicator, like the tab bar the home bar floats
      // over. The bar itself carries its own 8pt bottom margin.
      bottom: MediaQuery.of(context).padding.bottom,
      child: ValueListenableBuilder<bool>(
        valueListenable: observer.isMusicSubPage,
        builder: (context, isMusic, _) {
          final show = isMusic && MediaQuery.of(context).viewInsets.bottom == 0;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: show
                ? MiniPlayerBar(
                    // Key distinguishes the overlay bar from the home
                    // page's embedded bar in tests (same widget, two
                    // instances).
                    key: const ValueKey('overlayMiniPlayer'),
                    onOpenPlayer: (rect) {
                      unawaited(openPlayerPage<void>(context, fromRect: rect));
                    },
                  )
                : const SizedBox.shrink(key: ValueKey('overlayHidden')),
          );
        },
      ),
    );
  }
}
