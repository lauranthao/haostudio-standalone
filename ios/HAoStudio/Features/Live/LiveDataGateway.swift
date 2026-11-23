// HAo Studio 2.0 — live data gateway (S4-C leg).
//
// The ONE seam between the live UI (this leg) and the live
// services (B leg: the five platform site clients + danmaku
// transports) and the player core (A leg: LiveDriver).
//
// Why a protocol instead of calling the B-leg clients directly:
// the three S4 legs are built in parallel clones from the same
// seam commit, so the B-leg types do not exist in this clone yet.
// The UI below talks ONLY to this protocol (seam models only:
// LiveRoom). The B leg (or the merge coordinator) provides the
// adapter that maps these methods onto the site clients — no UI
// file changes are needed at merge.
//
// The gateway is OPTIONAL on the tab/search view models (nil =
// no source wired yet): the tab then shows the local rows
// (follows + history, real data) and an honest empty state for
// the recommend section — never fake rooms, never a dead button.
//
// Method shapes mirror the Flutter side:
// - LiveTabController: recommend rooms per platform + area
//   categories, pull to refresh, paged "load more".
// - LiveSearchPage: per-platform room search, keywords only in
//   history.
// - LiveRoomPage entry records history (L01) before opening.
//
// Swift 5.0: completion handlers only, no async/await, no `any`.
// All completions fire on the main queue.

import Foundation

/// One live platform. Only these five — the other 29 Pure Live
/// platforms are never added (chen 2026-11-16, seam contract).
struct LivePlatform: Equatable, Identifiable {
    let id: String
    let displayName: String

    static let bilibili = LivePlatform(id: "bilibili", displayName: "哔哩哔哩")
    static let douyu = LivePlatform(id: "douyu", displayName: "斗鱼")
    static let huya = LivePlatform(id: "huya", displayName: "虎牙")
    static let douyin = LivePlatform(id: "douyin", displayName: "抖音")
    static let kuaishou = LivePlatform(id: "kuaishou", displayName: "快手")

    /// The five platforms, in tab order (Flutter _PlatformRow).
    static let all: [LivePlatform] = [.bilibili, .douyu, .huya, .douyin, .kuaishou]

    static func platform(for id: String) -> LivePlatform? {
        all.first { $0.id == id }
    }
}

/// One page of rooms from a list endpoint. `hasMore` is false
/// when the last page returned fewer rooms than the page size, or
/// when the service says there is nothing after this page.
struct LiveRoomPage: Equatable {
    let rooms: [LiveRoom]
    let hasMore: Bool

    static let empty = LiveRoomPage(rooms: [], hasMore: false)
}

/// What the live UI needs from the services. Every method takes
/// the narrowest inputs and returns seam models only.
protocol LiveDataGateway {
    /// Recommended rooms for one platform, optionally inside one
    /// category (`area` nil = all categories). Page 0-based; an
    /// empty page means the end of the list.
    func fetchRecommended(
        platform: String,
        area: String?,
        page: Int,
        completion: @escaping (LiveRoomPage) -> Void
    )

    /// Category (area) names for the platform's category strip.
    /// Empty when the platform exposes no categories.
    func fetchCategories(
        platform: String,
        completion: @escaping ([String]) -> Void
    )

    /// Room search on one platform, fastest first. Empty query
    /// answers empty — the UI never searches a blank string.
    func searchRooms(
        query: String,
        platform: String,
        completion: @escaping ([LiveRoom]) -> Void
    )

    /// Full room detail (title / anchor / watching / cover /
    /// live status) for one room. Nil when the room cannot be
    /// resolved on its platform — the UI then keeps the card's
    /// stored values, never a fake detail.
    func fetchRoomDetail(
        room: LiveRoom,
        completion: @escaping (LiveRoom?) -> Void
    )
}

/// Watching count for a room card / room page ("1.2万" above ten
/// thousand, plain below — Pure Live's compact count).
func liveWatchingText(_ watching: Int) -> String {
    guard watching > 0 else { return "" }
    if watching >= 10000 {
        let value = Double(watching) / 10000
        if value >= 100 {
            return "\(Int(value))万"
        }
        return String(format: "%.1f万", value)
    }
    return "\(watching)"
}

/// Cover URL for a room card (B-leg `cover` is the raw string,
/// like the Flutter model; an empty string means no cover).
func liveCoverURL(for room: LiveRoom) -> URL? {
    guard !room.cover.isEmpty else { return nil }
    return URL(string: room.cover)
}

/// Avatar URL for an anchor row (empty string means no avatar).
func liveAvatarURL(for room: LiveRoom) -> URL? {
    guard !room.avatar.isEmpty else { return nil }
    return URL(string: room.avatar)
}
