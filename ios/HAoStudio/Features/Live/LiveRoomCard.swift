// HAo Studio 2.0 — live room card (S4-C leg).
//
// One room card, shared by the tab grid, search results, the
// follows page and the history page (Flutter _RoomCard):
// 16:10 cover, LIVE badge (theme liveRed — the only red in the
// app) when the room is live, title, anchor nick, watching
// count. No cover URL means the themed placeholder, never a fake
// image. Tapping is the caller's job (the card itself holds no
// navigation) so the same card works in every list.

import Foundation
import SwiftUI

/// A room card for a grid (tab / search). Fixed 16:10 cover.
struct LiveRoomCard: View {
    var room: LiveRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                coverView
                Text(room.title.isEmpty ? "直播间" : room.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(room.nick.isEmpty ? room.platform : room.nick)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if !liveWatchingText(room.watching).isEmpty {
                        Text(liveWatchingText(room.watching))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var coverView: some View {
        ZStack(alignment: .topLeading) {
            coverImage
                .aspectRatio(16.0 / 10.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if room.liveStatus {
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.liveRed, in: Capsule())
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let url = liveCoverURL(for: room) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    coverPlaceholder
                @unknown default:
                    coverPlaceholder
                }
            }
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// A room row for a list (follows / history): small cover thumb
/// + title + anchor + watching, chevron on the right.
struct LiveRoomRow: View {
    var room: LiveRoom
    var onTap: () -> Void

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                rowCover
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title.isEmpty ? "直播间" : room.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if room.liveStatus {
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.liveRed, in: Capsule())
                        }
                        Text(room.nick.isEmpty ? room.platform : room.nick)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    if !liveWatchingText(room.watching).isEmpty {
                        Text("\(liveWatchingText(room.watching)) 人在看")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowCover: some View {
        Group {
            if let url = liveCoverURL(for: room) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        rowCoverPlaceholder
                    @unknown default:
                        rowCoverPlaceholder
                    }
                }
            } else {
                rowCoverPlaceholder
            }
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var rowCoverPlaceholder: some View {
        Rectangle()
            .fill(theme.surfaceStrong)
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)
            }
    }
}

/// Relative time for a history row ("刚刚" / "5 分钟前" / "3 小时前" /
/// "昨天" / "3 天前" / date). Pure function of the two dates.
func liveRelativeTimeText(date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 {
        return "刚刚"
    }
    if seconds < 3600 {
        return "\(Int(seconds / 60)) 分钟前"
    }
    if seconds < 86400 {
        return "\(Int(seconds / 3600)) 小时前"
    }
    let days = Int(seconds / 86400)
    if days == 1 {
        return "昨天"
    }
    if days < 7 {
        return "\(days) 天前"
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
