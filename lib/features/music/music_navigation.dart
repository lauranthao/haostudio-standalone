import 'package:flutter/cupertino.dart';

/// Route name marking a music sub-page: search, daily, plaza, charts,
/// listening report, favourites, downloads, local files, playlist /
/// artist / album detail, and song comments.
///
/// The app-level mini player overlay shows only while the top route
/// carries this name. The full player (MusicPlayerPage), the equalizer,
/// and video / live / settings pages are pushed WITHOUT this name, so
/// the overlay never floats over them. Dialogs and bottom sheets are
/// PopupRoutes, so they hide the overlay too (the observer only treats
/// a PageRoute with this name as a music page).
const String musicSubPageRouteName = 'music';

/// Single-instance guard for the full player page (chen 2026-11-20:
/// tapping 心动模式 then switching songs opened multiple player pages).
///
/// Every "open the player" call site pushes a new MusicPlayerPage, and
/// the heartbeat / FM card handlers are async — a similar-song search
/// plus the first URL resolve run before the push — so a second open
/// during that window (a second card tap, a mini-bar tap once the bar
/// appears while the first URL is still resolving) stacked a second
/// player page on the route stack. Song-switch gestures themselves
/// (next / prev / queue tap) never push; the stacking came from the
/// unguarded opens.
///
/// [claimPlayerPage] is called synchronously by the one opener
/// (`openPlayerPage` in player_expand_route.dart) before it pushes;
/// it returns false when a player page is already open (or being
/// opened) and the caller must not push. [releasePlayerPage] runs when
/// the pushed route leaves the stack. The claim is held through the
/// pop animation (the push future completes when the route is fully
/// removed), so a tap in that ~300ms window is dropped instead of
/// opening a second page — the song still plays and the mini bar
/// appears, so nothing is lost.
bool _playerPageOpen = false;

/// Whether a full player page is open (or being opened) right now.
bool get isPlayerPageOpen => _playerPageOpen;

/// Claim the single player-page slot. Returns false when a player page
/// is already open (or being opened) — do not push another one.
bool claimPlayerPage() {
  if (_playerPageOpen) return false;
  _playerPageOpen = true;
  return true;
}

/// Release the player-page slot; called when the pushed route leaves
/// the stack. Idempotent.
void releasePlayerPage() {
  _playerPageOpen = false;
}

/// Test-only: drop a stale claim (a test that ends with the player
/// page still on the stack). Production never calls this — the push
/// future releases the claim when the route leaves.
@visibleForTesting
void resetPlayerPageGuardForTest() {
  _playerPageOpen = false;
}

/// Push a music sub-page, tagging its route so the mini player overlay
/// knows it belongs to the music area. Use this for every music
/// sub-page push; do NOT use it for the full player or the equalizer.
Future<T?> pushMusicSubPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(
    CupertinoPageRoute<T>(
      settings: const RouteSettings(name: musicSubPageRouteName),
      builder: (_) => page,
    ),
  );
}
