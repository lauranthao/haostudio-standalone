// HAo Studio 2.0 — video data gateway (S3-C leg).
//
// The ONE seam between the video UI (this leg) and the video
// services (B leg: CmsClient / DoubanService / EmbyClient /
// DownloadEngine) and the player core (A leg: VideoDriver).
//
// Why a protocol instead of calling the B-leg clients directly:
// the three S3 legs are built in parallel clones from the same
// seam commit, so the B-leg types do not exist in this clone yet.
// The UI below talks ONLY to this protocol (seam models only:
// VideoItem / VideoDetail / VideoHomeRow / VideoMeta). At merge,
// the coordinator adds one small adapter that maps these methods
// onto the B-leg clients — no UI file changes. Until then,
// VideoDataGatewayPlaceholder answers every call with an empty
// result, so the tab renders honest empty states instead of
// crashing or faking rows.
//
// Method shapes mirror the Flutter side (merge23):
// - CmsClient.search / detail / home / byType / typeMap
// - DoubanService.detail (title + year) — folded into fetchDetail
//   by the adapter, so the UI sees one merged VideoDetail.
// - EmbyClient.libraries / byGenre / movies / series / search —
//   mapped onto seam models (VideoItem / VideoDetail) by the
//   adapter; Emby-only shapes are the two small structs below.
// - DownloadEngine.enqueue — one call, Bool result.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.
// All completions fire on the main queue.

import Foundation

/// One Emby library (a media folder: 电影 / 电视剧 / ...).
/// The adapter maps it from the B-leg Emby models.
struct VideoEmbyLibrary: Equatable, Identifiable {
    let id: String
    let name: String
}

/// One page of items from a list endpoint. `hasMore` is false
/// when the last page returned fewer rows than the page size, or
/// when the service says there is nothing after this page.
struct VideoItemPage: Equatable {
    let items: [VideoItem]
    let hasMore: Bool

    static let empty = VideoItemPage(items: [], hasMore: false)
}

/// What the video UI needs from the services. Every method takes
/// the narrowest inputs and returns seam models only.
protocol VideoDataGateway {
    // MARK: - CMS home / browse / search / detail

    /// Home rows (category strips + recommendations). The adapter
    /// merges CmsClient.home rows with the daily row.
    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void)
    /// Category names for the tab's category strip.
    func fetchTypeNames(completion: @escaping ([String]) -> Void)
    /// One category page (0-based). Empty page = end of list.
    func fetchByType(_ type: String, page: Int, completion: @escaping (VideoItemPage) -> Void)
    /// CMS search across enabled sources, fastest first.
    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void)
    /// Full detail: CMS lines + Douban metadata merged. Nil when
    /// the title cannot be resolved on any source.
    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void)

    // MARK: - Emby

    /// True when an Emby server is configured (address + login).
    /// False until B leg wires the stored config — the Emby tab
    /// then shows the "not configured" state, never fake rows.
    var embyConfigured: Bool { get }
    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void)
    /// Genre names for the Genres chips.
    func fetchEmbyGenres(completion: @escaping ([String]) -> Void)
    /// Items in one library, or in one genre across libraries
    /// when `genre` is set (libraryId nil = all libraries).
    func fetchEmbyItems(
        libraryId: String?,
        genre: String?,
        page: Int,
        completion: @escaping (VideoItemPage) -> Void
    )
    /// Emby detail: streams as play lines. Movies get one line
    /// with one "正片" episode; series get one line per season
    /// group with one episode per item.
    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void)
    /// Emby library search.
    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void)

    // MARK: - Download

    /// Queue one episode for download (B-leg DownloadEngine).
    /// True when the task was queued; false when the engine is
    /// not installed or the episode has no URL to fetch yet.
    func enqueueDownload(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        completion: @escaping (Bool) -> Void
    )
}

/// Empty gateway: every call answers with nothing, on the main
/// queue. Used until the merge adapter lands. The UI treats an
/// empty answer as "no data", never as an error to retry in a loop.
final class VideoDataGatewayPlaceholder: VideoDataGateway {
    var embyConfigured: Bool { false }

    func fetchHome(completion: @escaping ([VideoHomeRow]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func fetchTypeNames(completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func fetchByType(_ type: String, page: Int, completion: @escaping (VideoItemPage) -> Void) {
        DispatchQueue.main.async { completion(.empty) }
    }

    func search(keyword: String, completion: @escaping ([VideoItem]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func fetchDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }

    func fetchEmbyLibraries(completion: @escaping ([VideoEmbyLibrary]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func fetchEmbyGenres(completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func fetchEmbyItems(
        libraryId: String?,
        genre: String?,
        page: Int,
        completion: @escaping (VideoItemPage) -> Void
    ) {
        DispatchQueue.main.async { completion(.empty) }
    }

    func fetchEmbyDetail(item: VideoItem, completion: @escaping (VideoDetail?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }

    func searchEmby(keyword: String, completion: @escaping ([VideoItem]) -> Void) {
        DispatchQueue.main.async { completion([]) }
    }

    func enqueueDownload(
        detail: VideoDetail,
        episode: PlayEpisode,
        line: PlayLine,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async { completion(false) }
    }
}

/// The single place the app asks for a gateway. The coordinator
/// swaps this factory body for the B-leg adapter at merge; no
/// view file names a concrete client.
enum VideoServices {
    static func makeGateway() -> VideoDataGateway {
        VideoDataGatewayPlaceholder()
    }
}
