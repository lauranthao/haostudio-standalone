// HAo Studio 2.0 — mini player strip + full-player placeholder.
//
// The mini player is a floating glass strip ABOVE the tab bar. Tapping it
// opens the full player. S2-C wiring:
// - The strip appears when the PlaybackCoordinator has a current item.
// - For MUSIC items it shows a real play/pause button bound to
//   NativeMusicPlayer (via the shared MusicPlayerViewModel); for VOD /
//   live items it shows no transport button (their players are other
//   slices' — a button with no engine behind it would be fake).
// - Tapping the strip opens the full player (music: the real player).

import SwiftUI

/// Floating mini-player strip. Hidden entirely when there is no current item.
struct MiniPlayerBar: View {
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @EnvironmentObject private var musicPlayer: MusicPlayerViewModel
    @Environment(\.haoTheme) private var theme

    /// Opens the full player (foundation: the empty-state placeholder).
    var onTapFullPlayer: () -> Void

    var body: some View {
        if let item = coordinator.currentItem {
            // No nested Buttons: the strip tap area, the play/pause
            // button and the chevron are SIBLING buttons. A play/pause
            // Button nested inside the strip Button would also fire
            // the strip tap and open the full player on every pause.
            HStack(spacing: 12) {
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.kind == .music {
                    Button(action: { musicPlayer.togglePlayPause() }) {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(musicPlayer.isPlaying ? "暂停" : "播放")
                }
                Button(action: onTapFullPlayer) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 24, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: HaoLayout.miniPlayerHeight)
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
