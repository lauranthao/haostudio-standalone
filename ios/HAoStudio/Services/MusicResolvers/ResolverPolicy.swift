// ResolverPolicy.swift
// Resolver policy, pure and unit-testable (no JS, no network):
// speed ranking + cooldown, play-URL cache, pass budgets.
//
// Flutter parity (`music_resolvers.dart`):
// - Success updates an EMA latency (70% old / 30% new) and resets
//   the failure streak; an error bumps the streak and cools the job
//   after 3 consecutive failures (5 min); a TIMEOUT cools the job
//   immediately (2 min); an EMPTY answer records nothing at all (a
//   source that is fast but has no stock at this tier must not be
//   cooled out of the tiers it does serve).
// - Speeds persist under the S1 mapping key `hao_resolver_speed`
//   (`Documents/hao_resolver_speed.json`); persistence is
//   best-effort and throttled (every 10 attempts or 5 s).
// - Play-URL cache: 1 h TTL, 200-entry cap, key
//   `songId|platform|quality`. The 1 h TTL is uniform: no source
//   publishes a real expiry, so per-source TTLs would be invented
//   numbers — instead an URL that fails at playback is evicted
//   explicitly (`evictPlayUrl`), and the cache is in-memory only
//   (the `hao_play_url_cache:` family is NOT migrated, per S1).
// - Budgets (P0-16 rework): a whole resolve is capped at 8 s; the
//   FIRST tier pass is capped at 5 s and 3 s are reserved for the
//   lower tiers (each later pass at most 2 s); a single job is
//   capped at 3 s. The first tier can never eat the whole budget.

import Foundation

// MARK: - Budgets (P0-16)

enum ResolverBudget {
    /// Whole-resolve deadline.
    static let total: TimeInterval = 8
    /// First tier pass cap — 3 s stay reserved for lower tiers.
    static let firstPassCap: TimeInterval = 5
    /// Later tier pass cap.
    static let laterPassCap: TimeInterval = 2
    /// Single job cap.
    static let perJob: TimeInterval = 3

    /// Pass budget for pass `index` (0 = first tier), bounded by
    /// the time remaining in the whole resolve.
    static func passBudget(passIndex: Int, remaining: TimeInterval) -> TimeInterval {
        let cap = passIndex == 0 ? firstPassCap : laterPassCap
        return min(cap, remaining)
    }
}

// MARK: - Speed ranking + cooldown

/// One job's persisted speed record (`hao_resolver_speed.json`).
struct ResolverSpeedRecord: Codable {
    var avg: Int?
    var fails: Int?
    var cooledUntilMs: Int?

    enum CodingKeys: String, CodingKey {
        case avg
        case fails
        case cooled
    }

    init(avg: Int? = nil, fails: Int? = nil, cooledUntilMs: Int? = nil) {
        self.avg = avg
        self.fails = fails
        self.cooledUntilMs = cooledUntilMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        avg = try container.decodeIfPresent(Int.self, forKey: .avg)
        fails = try container.decodeIfPresent(Int.self, forKey: .fails)
        cooledUntilMs = try container.decodeIfPresent(Int.self, forKey: .cooled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(avg, forKey: .avg)
        try container.encodeIfPresent(fails, forKey: .fails)
        try container.encodeIfPresent(cooledUntilMs, forKey: .cooled)
    }
}

/// Speed ranking + cooldown for resolver jobs. Threading: the
/// resolver calls this only from its serial work queue; tests call
/// it directly. `now` is injectable for tests.
final class ResolverCooldown {
    static let speedKey = "hao_resolver_speed"
    /// Unknown speed sorts in the middle (Flutter: 500 ms).
    static let unknownSpeedMs = 500
    static let coolAfterFails = 3
    static let coolFor: TimeInterval = 5 * 60
    static let coolTimeoutFor: TimeInterval = 2 * 60

    private(set) var averages: [String: Int] = [:]
    private(set) var fails: [String: Int] = [:]
    private(set) var cooledUntil: [String: Date] = [:]

    private let documentsDirectory: URL?
    private var attemptsSinceSave = 0
    private var lastSaveAt = Date()
    var now: () -> Date = { Date() }

    init(documentsDirectory: URL? = nil) {
        self.documentsDirectory = documentsDirectory
        load()
    }

    // MARK: - Recording

    enum Outcome {
        case success
        case empty
        case error
        case timeout
    }

    func record(_ key: String, outcome: Outcome, milliseconds: Int) {
        switch outcome {
        case .success:
            let prev = averages[key]
            averages[key] = prev == nil ? milliseconds : (prev! * 7 + milliseconds * 3) / 10
            fails.removeValue(forKey: key)
            cooledUntil.removeValue(forKey: key)
        case .empty:
            // A fast "no" is not a failure — nothing changes.
            return
        case .error:
            let count = (fails[key] ?? 0) + 1
            fails[key] = count
            if count >= Self.coolAfterFails {
                cooledUntil[key] = now().addingTimeInterval(Self.coolFor)
            }
        case .timeout:
            let count = (fails[key] ?? 0) + 1
            fails[key] = count
            cooledUntil[key] = now().addingTimeInterval(Self.coolTimeoutFor)
        }
        attemptsSinceSave += 1
        if attemptsSinceSave >= 10 || now().timeIntervalSince(lastSaveAt) >= 5 {
            attemptsSinceSave = 0
            save()
        }
    }

    func isCoolingDown(_ key: String) -> Bool {
        guard let until = cooledUntil[key] else { return false }
        if now() < until { return true }
        cooledUntil.removeValue(forKey: key)
        return false
    }

    func averageMs(_ key: String) -> Int {
        averages[key] ?? Self.unknownSpeedMs
    }

    func saveNow() {
        save()
    }

    // MARK: - Persistence (best-effort)

    private func load() {
        guard let dir = documentsDirectory ?? LocalStore.documentsDirectoryOrNil() else { return }
        let url = dir.appendingPathComponent("\(Self.speedKey).json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: ResolverSpeedRecord].self, from: data)
        else { return }
        for (key, record) in map {
            if let avg = record.avg { averages[key] = avg }
            if let fails = record.fails { self.fails[key] = fails }
            if let ms = record.cooledUntilMs {
                cooledUntil[key] = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            }
        }
    }

    private func save() {
        guard let dir = documentsDirectory ?? LocalStore.documentsDirectoryOrNil() else { return }
        lastSaveAt = now()
        var map: [String: ResolverSpeedRecord] = [:]
        for key in Set(averages.keys).union(fails.keys).union(cooledUntil.keys) {
            map[key] = ResolverSpeedRecord(
                avg: averages[key],
                fails: fails[key],
                cooledUntilMs: cooledUntil[key].map { Int($0.timeIntervalSince1970 * 1000) })
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(
            to: dir.appendingPathComponent("\(Self.speedKey).json"),
            options: [.atomic])
    }
}

// MARK: - Play-URL cache (1 h TTL, 200-entry cap, in-memory)

/// One cached play URL with the tier it was actually served at.
struct CachedPlayURL {
    let url: String
    let tier: AudioQuality
    let expiresAt: Date
}

final class PlayURLCache {
    static let ttl: TimeInterval = 60 * 60
    static let maxEntries = 200

    private var entries: [String: CachedPlayURL] = [:]
    /// Insertion order (oldest first) for the 200-entry cap.
    private var order: [String] = []
    var now: () -> Date = { Date() }

    static func key(songId: String, platform: String, quality: AudioQuality) -> String {
        "\(songId)|\(platform)|\(quality.lxCode)"
    }

    func get(_ key: String) -> CachedPlayURL? {
        guard let entry = entries[key] else { return nil }
        if now() >= entry.expiresAt {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry
    }

    func put(_ key: String, url: String, tier: AudioQuality) {
        if entries[key] == nil {
            order.append(key)
            while order.count > Self.maxEntries, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = CachedPlayURL(url: url, tier: tier, expiresAt: now().addingTimeInterval(Self.ttl))
    }

    /// Drop a cached URL (e.g. it failed at playback): the next
    /// resolve for this song re-asks the sources.
    func evict(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    var count: Int { entries.count }
}

private extension LocalStore {
    /// Documents directory, nil when the app container is unavailable
    /// (unit tests without a host app). Never throws.
    static func documentsDirectoryOrNil() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
