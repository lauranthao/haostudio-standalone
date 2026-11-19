import 'package:flutter/material.dart';

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

/// Push a music sub-page, tagging its route so the mini player overlay
/// knows it belongs to the music area. Use this for every music
/// sub-page push; do NOT use it for the full player or the equalizer.
Future<T?> pushMusicSubPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      settings: const RouteSettings(name: musicSubPageRouteName),
      builder: (_) => page,
    ),
  );
}
