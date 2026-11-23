// HAo Studio 2.0 — music discovery pages (S2-C leg).
//
// Daily picks, plaza, charts, listen report.
//
// - Daily: cached per day (hao_daily.json); a missing day is built
//   from local data (most-played + top artists, seeded by day).
// - Listen report: pure local aggregation of the listen log
//   (Flutter ListenReport.compute).
// - Plaza needs platform APIs that are NOT in the LX contract
//   (playlist browsing). Its page shows an honest empty state
//   with the reason — no fake rows are invented. The plaza
//   platform picker still works (it persists the choice for when
//   the API lands).
// - Charts moved to MusicChartsView.swift (S3-C): NetEase toplist
//   via the existing music API, no new protocol.

import SwiftUI

// MARK: - Daily

struct MusicDailyView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        Group {
            if discoveryVM.dailyTracks.isEmpty {
                MusicEmptyState(
                    icon: "calendar", title: "今天还没有推荐",
                    note: "先收藏几首歌或播几首歌，每日推荐会从你听过的歌里挑。"
                )
            } else {
                List {
                    ForEach(Array(discoveryVM.dailyTracks.enumerated()), id: \.element.id) { index, song in
                        MusicSongRow(
                            song: song,
                            isPlaying: playerVM.currentSong?.identityKey == song.identityKey && playerVM.isPlaying,
                            onTap: {
                                playerVM.play(song: song, in: discoveryVM.dailyTracks, startAt: index)
                            },
                            onToggleFav: {
                                _ = MusicLibraryStore.toggleFav(song)
                            }
                        )
                        .listRowBackground(theme.scaffoldBackground)
                        .listRowSeparatorTint(theme.hairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MusicCapsuleButton(icon: "play.fill", label: "播放全部", enabled: !discoveryVM.dailyTracks.isEmpty) {
                    playerVM.playAll(discoveryVM.dailyTracks)
                }
            }
        }
        .onAppear { discoveryVM.reload() }
    }
}

// MARK: - Plaza

struct MusicPlazaView: View {
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    private let platforms: [MusicPlatform] = [.wy, .tx, .kw, .kg]

    var body: some View {
        VStack(spacing: 0) {
            Picker("平台", selection: Binding(
                get: { discoveryVM.plazaPlatform },
                set: { discoveryVM.setPlazaPlatform($0) }
            )) {
                ForEach(platforms, id: \.rawValue) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            MusicEmptyState(
                icon: "square.grid.2x2", title: "歌单广场尚未上线",
                note: "这里以后会按平台列出歌单。"
            )
            Spacer()
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("歌单广场")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.reload() }
    }
}

// MARK: - Listen report

struct MusicListenReportView: View {
    @EnvironmentObject private var playerVM: MusicPlayerViewModel
    @StateObject private var discoveryVM = MusicDiscoveryViewModel()

    @Environment(\.haoTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("范围", selection: $discoveryVM.reportRange) {
                    ForEach(ListenReportRange.allCases, id: \.rawValue) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                summaryCard
                topSongsSection
                topArtistsSection
                topPlatformsSection
                perDaySection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(theme.scaffoldBackground)
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { discoveryVM.reload() }
    }

    private var summaryCard: some View {
        let report = discoveryVM.report
        let hours = report.totalSeconds / 3600
        let minutes = (report.totalSeconds % 3600) / 60
        return HStack(spacing: 0) {
            summaryStat(value: "\(report.totalPlays)", label: "播放次数")
            Divider().background(theme.hairline)
            summaryStat(value: hours > 0 ? "\(hours)小时\(minutes)分" : "\(minutes)分", label: "收听时长")
            Divider().background(theme.hairline)
            summaryStat(value: "\(report.topSongs.count)", label: "听过的歌")
        }
        .padding(.vertical, 16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topSongs.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(discoveryVM.report.topSongs.prefix(10).enumerated()), id: \.element.song.id) { rank, top in
                    HStack(spacing: 12) {
                        Text("\(rank + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 20)
                        MusicSongRow(
                            song: top.song,
                            showPlatformBadge: false,
                            isPlaying: playerVM.currentSong?.identityKey == top.song.identityKey && playerVM.isPlaying,
                            onTap: {
                                let songs = discoveryVM.report.topSongs.map { $0.song }
                                if let index = songs.firstIndex(where: { $0.identityKey == top.song.identityKey }) {
                                    playerVM.play(song: top.song, in: songs, startAt: index)
                                }
                            }
                        )
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
    }

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最常听的歌手")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topArtists.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topArtists.prefix(10), id: \.artist) { top in
                    HStack {
                        Text(top.artist)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var topPlatformsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("来源平台")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.topPlatforms.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.topPlatforms, id: \.platform) { top in
                    HStack {
                        Text(top.platform.displayName)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(top.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var perDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(discoveryVM.reportRange == .all ? "按月" : "按天")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if discoveryVM.report.perDay.isEmpty {
                Text("这段时间还没有收听记录。")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(discoveryVM.report.perDay, id: \.label) { day in
                    HStack {
                        Text(day.label)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(day.plays) 次")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
