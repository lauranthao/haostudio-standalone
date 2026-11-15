import ActivityKit
import SwiftUI
import WidgetKit

// Widget extension bundle for the HAo Studio lyrics Live Activity.
// Shows the current lyric line on the lock screen ONLY — the Dynamic
// Island shows just the song title / artist (like a normal music app)
// and never shows lyrics. The activity itself is started / updated /
// ended by the main app (LyricsLiveActivity in the HAoStudio target);
// this file only draws it.

@main
struct HAoStudioLyricsBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivityWidget()
    }
}

struct LyricsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsAttributes.self) { context in
            // Lock screen: lyric line ONLY, floating on the wallpaper
            // like Apple Music — no card, no title/artist, no play
            // status. The system Now Playing card directly above
            // already shows title, artist and play state; duplicating
            // them is what made ours look like a separate widget.
            // (A third-party app cannot put lyrics inside the system
            // Now Playing card itself — MPNowPlayingInfoCenter has no
            // lyrics field — so the Live Activity is the only surface
            // we control, made to read as floating lyric text.)
            Text(context.state.line.isEmpty ? "♪" : context.state.line)
                .font(.system(size: 22, weight: .bold))
                // Black, not white: on iOS 26 the lock-screen Live
                // Activity card renders as a WHITE glass card, so the
                // old white text was invisible (the card looked empty
                // even though the lyric line was there).
                .foregroundColor(.black)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .activityBackgroundTint(Color.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.caption)
                            .bold()
                            .lineLimit(1)
                        Text(context.attributes.artist)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    // No lyrics here: the Dynamic Island shows title /
                    // artist only. The lyric line lives on the lock
                    // screen Live Activity view.
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundColor(Color(red: 0.9, green: 0.28, blue: 0.3))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(context.state.isPlaying ? "正在播放" : "已暂停")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundColor(Color(red: 0.9, green: 0.28, blue: 0.3))
            } compactTrailing: {
                // Song title only — never the lyric line.
                Text(context.attributes.title)
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundColor(Color(red: 0.9, green: 0.28, blue: 0.3))
            }
        }
    }
}
