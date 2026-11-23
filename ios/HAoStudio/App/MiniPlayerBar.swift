// HAo Studio 2.0 — mini player strip + full-player placeholder.
//
// The mini player is a floating glass strip ABOVE the tab bar. Tapping it
// opens the full player. In the foundation slice there is NO playback
// engine, so:
// - The strip only appears when the PlaybackCoordinator has a current
//   item (nothing in the foundation UI creates one, so it is hidden
//   until the player slice lands).
// - The strip has NO play/pause button: a button with no engine behind
//   it would be fake playback, and a disabled button would be a dead
//   control. It shows the track title/artist + a chevron into the full
//   player. The player slice adds transport controls here.
// - The full player is an explicit empty state ("播放器是后续 slice"),
//   not a mock player: no fake progress, no fake play button.

import SwiftUI

/// Floating mini-player strip. Hidden entirely when there is no current item.
struct MiniPlayerBar: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.haoTheme) private var theme

    /// Opens the full player (foundation: the empty-state placeholder).
    var onTapFullPlayer: () -> Void

    var body: some View {
        if let item = coordinator.currentItem {
            Button(action: onTapFullPlayer) {
                HStack(spacing: 12) {
                    // Cover slot: theme surface until the player slice
                    // supplies real artwork.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceStrong)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: HaoLayout.miniPlayerHeight)
            }
            .buttonStyle(.plain)
            .haoGlassCapsule()
            .accessibilityLabel("迷你播放器：\(item.title)，点按打开全屏播放器")
        }
    }
}

/// Full-player empty state for the foundation slice. The real player
/// (music / VOD / live) arrives in the player slice; this view only
/// proves the navigation path from the mini player exists and never
/// pretends anything is playing.
struct FullPlayerPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @Environment(\.haoTheme) private var theme

    var body: some View {
        ZStack {
            theme.scaffoldBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("播放器")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                if let item = coordinator.currentItem {
                    Text(item.title)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textSecondary)
                }
                Text("播放器是后续 slice，此处为空态占位。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textMuted)
            }
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(theme.surfaceStrong, in: Circle())
            }
            .padding(16)
            .accessibilityLabel("关闭播放器")
        }
    }
}
