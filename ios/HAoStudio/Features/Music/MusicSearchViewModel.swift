// HAo Studio 2.0 — music search view model (S2-C leg).
//
// Streaming search (Flutter SongSearchService.searchAllStream):
// - one query searches ALL platforms by default — there is NO
//   platform selector in this UI (chen's rule; the search-platform
//   capsule in Flutter is not carried over);
// - each settled leg appends its batch through the merge (first
//   result ~1s, no waiting for the slowest leg; NetEase + QQ first);
// - search history (max 20, newest first) is saved on every
//   submitted query.
//
// Finality: the LX contract's completion handler is called once per
// settled leg batch and carries no "done" flag (see the C-leg
// report). The "searching" footer therefore settles by quiet: no
// batch for 10 s (the per-platform timeout Flutter used) means the
// search is done. A new batch re-arms it.

import Combine
import SwiftUI

@MainActor
final class MusicSearchViewModel: ObservableObject {
    @Published var keyword = ""
    @Published private(set) var results: [MusicSong] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var history: [String] = []

    /// Seconds of quiet after the last batch before the search is
    /// considered settled (Flutter's per-platform search timeout).
    static let settleQuietSeconds: TimeInterval = 10

    private var merge = MusicSearchMerge()
    private var settleTimer: Timer?
    private var currentQuery = ""

    init() {
        history = MusicLibraryStore.getSearchHistory()
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentQuery = trimmed
        keyword = trimmed
        merge.reset()
        results = []
        hasSearched = true
        isSearching = true
        armSettleTimer()
        MusicLibraryStore.saveSearchQuery(trimmed)
        history = MusicLibraryStore.getSearchHistory()
        MusicSearchAPI.search(keyword: trimmed) { [weak self] batch in
            guard let self = self else { return }
            // Stale leg from an older query: drop it, never mix.
            guard trimmed == self.currentQuery else { return }
            let songs = batch.map(MusicSong.init(from:))
            self.merge.appendBatch(songs)
            self.results = self.merge.tracks
            self.isSearching = true
            self.armSettleTimer()
        }
    }

    /// A new query cancels the old one: results clear immediately and
    /// late batches from the old query are dropped by the query check.
    func clear() {
        keyword = ""
        currentQuery = ""
        merge.reset()
        results = []
        hasSearched = false
        isSearching = false
        settleTimer?.invalidate()
        settleTimer = nil
    }

    func clearHistory() {
        MusicLibraryStore.clearSearchHistory()
        history = []
    }

    func removeHistoryItem(_ query: String) {
        MusicLibraryStore.removeSearchQuery(query)
        history = MusicLibraryStore.getSearchHistory()
    }

    private func armSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleQuietSeconds, repeats: false) { [weak self] _ in
            self?.isSearching = false
        }
    }
}
