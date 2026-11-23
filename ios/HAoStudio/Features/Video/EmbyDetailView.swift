// HAo Studio 2.0 — Emby detail page (S3-C leg).
//
// The Emby detail layout is the same Infuse-style detail as CMS
// (cover top, big play button below, lines + episode grid) —
// Emby streams arrive as play lines through the gateway, so the
// page is the shared VideoDetailContentView with an Emby loader
// (VideoDetailSource.emby). No second layout is kept.
//
// Server-side actions (mark played, server favourite, playback
// reporting) need B-leg EmbyClient mutation APIs and are NOT
// faked here: the local favourite / resume in the shared detail
// view are the only actions until those APIs land.

import SwiftUI

struct EmbyDetailView: View {
    var item: VideoItem

    var body: some View {
        VideoDetailView(item: item, source: .emby)
    }
}
