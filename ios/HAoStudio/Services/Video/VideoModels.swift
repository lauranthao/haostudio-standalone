// HAo Studio 2.0 — video models (S3 seam).
//
// Swift mirrors of the Flutter video models
// (standalone-app-merge23 lib/features/video/video_models.dart and
// lib/features/video/cms_sources.dart). Field names follow the
// Flutter originals so a reader can diff the two sides; behaviour
// differences are called out in comments. Leg B (services) fills
// these from CMS / Douban / Emby JSON; Leg C (UI) renders them;
// Leg A (player) consumes episodes + lines only.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.

import Foundation

/// One CMS source. Shipped defaults live in CmsClient (Leg B);
/// the user list is persisted under the same Hive key name the
/// Flutter side uses (`hao_sa_video`) via MigrationStore's mapping,
/// so a migrated user keeps their sources.
struct VideoSource: Codable, Equatable, Identifiable {
    /// CMS source id (drifts on reseed — never hardcode video ids
    /// against it, never assume it survives a reseed).
    let id: Int
    let name: String
    let apiUrl: String
    /// "play" = trusted for playback, "search" = search only
    /// (play URLs not trusted — Flutter: 非凡 / 非凡主站).
    let kind: String
    let enabled: Bool
    /// Lower sorts first (Flutter: measured 2026-11-17, relative).
    let sort: Int

    var isPlaySource: Bool { kind == "play" }
}

/// One title in a list / search result. `id` is the CMS vod_id as
/// a string (ids drift on reseed; the stable identity for resume
/// is title + year, see VideoResumeKey).
struct VideoItem: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let title: String
    let coverURL: URL?
    /// Release year as printed by the source ("2024"); nil when the
    /// source does not give one. Douban year-check (Leg B) uses it.
    let year: String?
    let typeName: String?
    let remarks: String?
    /// CMS source this item came from (nil for Emby / Douban rows).
    let sourceId: Int?
}

/// One playable episode inside a line.
struct PlayEpisode: Codable, Equatable, Identifiable {
    /// Episode name as printed ("第01集", "正片"). Empty from the
    /// source means "正片" (Flutter cms_client.dart).
    let name: String
    let url: URL?
    /// Position inside its line (0-based). Display numbering uses
    /// this, never the parsed number inside `name`.
    let index: Int

    var id: String { "\(index)-\(name)" }
}

/// One playback line （线路）: a named group of episodes from one
/// source path. The UI shows the line name; switching lines keeps
/// the episode index and resumes at the same position.
struct PlayLine: Codable, Equatable, Identifiable {
    let name: String
    let episodes: [PlayEpisode]

    var id: String { name }

    func episode(at index: Int) -> PlayEpisode? {
        guard episodes.indices.contains(index) else { return nil }
        return episodes[index]
    }
}

/// Metadata for a title. Douban is the SOLE metadata source (TMDB
/// removed — no TMDB calls, keys, or references anywhere).
struct VideoMeta: Codable, Equatable {
    let rating: Double?
    let year: String?
    let cast: [String]
    let synopsis: String?
    /// Douban subject id when known (used for the detail fetch).
    let doubanId: String?
}

/// Full detail for a title: the item, its play lines, and metadata.
/// `lines` is empty until the detail fetch resolves (CMS detail or
/// Emby streams); the detail view shows the cover + meta first and
/// fills the episode grid when lines arrive.
struct VideoDetail: Codable, Equatable {
    let item: VideoItem
    let lines: [PlayLine]
    let meta: VideoMeta?

    /// The line the player should open: first line with episodes.
    var firstPlayableLine: PlayLine? {
        lines.first { !$0.episodes.isEmpty }
    }
}

/// Stable resume identity. A CMS vod_id is NOT stable (ids drift on
/// reseed), so resume keys are title + year, exactly like the
/// Flutter side (ResumeInfo key). Two titles that share a title and
/// year collide on purpose — the Flutter side does the same.
enum VideoResumeKey {
    static func key(title: String, year: String?) -> String {
        let y = (year ?? "").trimmingCharacters(in: .whitespaces)
        return y.isEmpty ? title : "\(title)-\(y)"
    }

    /// PlaybackItem id for an episode: resume key + episode name.
    /// The coordinator, history and resume all use this one string.
    static func episodeId(title: String, year: String?, episodeName: String) -> String {
        "\(key(title: title, year: year))#\(episodeName)"
    }
}

/// One resume bookmark: where playback stopped, so the next open
/// continues at the same episode and position. Persisted by
/// VideoLibraryStore (Leg C) under the resume key.
struct ResumeInfo: Codable, Equatable {
    let key: String
    let episodeName: String
    let episodeIndex: Int
    let positionSeconds: Double
    let durationSeconds: Double
    let updatedAt: Date
}

/// One row on the video home tab (a category strip / recommendation
/// row). `items` are VideoItems; the row title is shown as-is.
struct VideoHomeRow: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let items: [VideoItem]
}
