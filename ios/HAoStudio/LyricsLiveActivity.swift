import ActivityKit
import Foundation
import MediaPlayer

// One timed lyric line: `time` is seconds from the start of the song.
struct LyricsLine {
    let time: Double
    let text: String
}

// Parse LRC text ([mm:ss.xx]line) into timed lines. Handles several
// timestamps on one line (same text at several times) and skips
// metadata tags ([ti:], [ar:], [al:], [by:], [offset:]) and empty
// lines. Result is sorted by time.
func parseLRC(_ lrc: String) -> [LyricsLine] {
    let pattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var out: [LyricsLine] = []
    for rawLine in lrc.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { continue }
        // Text after the last timestamp on the line.
        let last = matches.last!
        let textStart = last.range.location + last.range.length
        let text = textStart < ns.length ? ns.substring(from: textStart).trimmingCharacters(in: .whitespaces) : ""
        guard !text.isEmpty else { continue }
        for m in matches {
            let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var frac = 0.0
            if m.range(at: 3).location != NSNotFound {
                let f = ns.substring(with: m.range(at: 3))
                frac = (Double(f) ?? 0) / pow(10.0, Double(f.count))
            }
            out.append(LyricsLine(time: min * 60 + sec + frac, text: text))
        }
    }
    return out.sorted { $0.time < $1.time }
}

// Synced-lyrics Live Activity (lock screen + Dynamic Island), one at a
// time. Two drivers share it:
//  - the native player (NPC): a lyrics-carrying stream drives the
//    position from its own playback clock via sync(position:playing:);
//  - the web music player: the web page posts song + LRC + position,
//    and this manager's timer advances the position while playing.
// The most recent start wins; end(owner:) only ends the activity when
// the caller owns it, so closing the native player does not kill a
// music activity it did not start (and vice versa).
// All ActivityKit work is gated to iOS 16.2; on iOS 15 the calls are
// no-ops and the app behaves exactly as before.
// ADDITIVE, music only: the same timed lines also drive the system
// Now Playing card (Control Center widget + lock screen Now Playing)
// via the 歌一刀 trick — the card has no lyrics field, so the current
// lyric line is written into its artist field (title stays the song
// title, the real artist name is kept in the album field). The web
// Media Session re-asserts artist = real artist on every play/pause,
// so the 0.5s timer re-checks and heals the override within half a
// second. The NPC ("npc" owner) is never touched: it owns Now Playing
// while it is on screen, and the sync is skipped unless the card is
// actually showing this song's title.
@available(iOS 16.2, *)
final class LyricsLiveActivity {
    static let shared = LyricsLiveActivity()
    private init() {}

    private var activity: Activity<LyricsAttributes>?
    private var owner: String = ""
    private var key: String = ""
    private var title: String = ""
    private var artist: String = ""
    private var lines: [LyricsLine] = []
    private var position: Double = 0
    private var playing: Bool = false
    // When true the caller drives the position (NPC tick); when false
    // this manager's own timer advances it (web music player).
    private var externalDrive: Bool = false
    private var lastLineIndex: Int = -2
    private var timer: Timer?
    // Last artist value this manager wrote into the system Now Playing
    // card (a lyric line, or the real artist name). Used only to know
    // whether end() has anything to restore.
    private var lastNowPlayingArtist: String? = nil

    // Start (or refresh) the activity for a song / stream. `key`
    // identifies the item (song id / stream title): re-posting the
    // same key (lyrics arriving late) keeps the activity and just
    // swaps in the real lines instead of flashing a new one.
    func start(owner: String, key: String, title: String, artist: String, lines: [LyricsLine], position: Double, externalDrive: Bool) {
        guard !lines.isEmpty else { return }
        if key == self.key, activity != nil {
            self.lines = lines
            self.position = position
            self.title = title
            self.artist = artist
            self.externalDrive = externalDrive
            updateActivity(force: true)
            return
        }
        end()
        self.owner = owner
        self.key = key
        self.title = title
        self.artist = artist
        self.lines = lines
        self.position = position
        self.playing = true
        self.externalDrive = externalDrive
        self.lastLineIndex = -2
        let attrs = LyricsAttributes(title: title, artist: artist)
        let state = LyricsAttributes.ContentState(line: lineText(at: position), isPlaying: true)
        do {
            activity = try Activity.request(attributes: attrs, contentState: state, pushType: nil)
        } catch {
            // Live Activities disabled in Settings, or the system
            // refused the request: no lock screen card, but do NOT
            // return — the timer below still runs so the Now Playing
            // lyric line keeps working. Playback is unaffected.
            activity = nil
        }
        startTimer()
    }

    // The NPC's playback clock: absolute position + playing state.
    // Only pushes an update when the lyric line actually changed.
    func sync(position: Double, playing: Bool) {
        self.position = position
        self.playing = playing
        updateActivity(force: false)
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        updateActivity(force: true)
    }

    func seek(to position: Double) {
        self.position = position
        updateActivity(force: true)
    }

    // End the activity, but only if `owner` started it.
    func end(owner: String) {
        guard self.owner == owner || self.owner.isEmpty else { return }
        end()
    }

    func end() {
        timer?.invalidate()
        timer = nil
        // Music stop: give the Now Playing artist field back to the
        // real artist name if we had replaced it with a lyric line.
        // Runs while owner/title are still the old song's.
        if owner == "music" {
            restoreMusicNowPlayingArtist()
        }
        lastNowPlayingArtist = nil
        if let a = activity {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        owner = ""
        key = ""
        lines = []
        lastLineIndex = -2
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // NPC-driven activities get their position from the player
            // clock; only advance the clock here for the music path.
            if self.playing, !self.externalDrive { self.position += 0.5 }
            self.updateActivity(force: false)
        }
    }

    private func lineIndex(at position: Double) -> Int {
        var idx = -1
        for (i, l) in lines.enumerated() {
            if l.time <= position + 0.2 { idx = i } else { break }
        }
        return idx
    }

    private func lineText(at position: Double) -> String {
        let idx = lineIndex(at: position)
        return idx >= 0 ? lines[idx].text : ""
    }

    private func updateActivity(force: Bool) {
        let idx = lineIndex(at: position)
        let line = idx >= 0 ? lines[idx].text : ""
        // 歌一刀 trick, music only: keep the system Now Playing card's
        // artist field showing the current lyric line. Runs on every
        // timer tick (not just on line change) so a web Media Session
        // re-assert is healed within 0.5s; the sync itself writes
        // only when the displayed artist differs. Skipped for the NPC
        // owner, which owns Now Playing while it is on screen.
        if owner == "music" {
            syncMusicNowPlaying(line: line)
        }
        guard let a = activity else { return }
        if !force, idx == lastLineIndex { return }
        lastLineIndex = idx
        let state = LyricsAttributes.ContentState(line: line, isPlaying: playing)
        Task { await a.update(using: state) }
    }

    // Put the current lyric line into the system Now Playing card's
    // artist field (Control Center widget line 2 + lock screen Now
    // Playing), the way 歌一刀 does it. Mutates the existing
    // nowPlayingInfo dictionary in place, so the web Media Session's
    // title, artwork, duration and playback rate are preserved. The
    // real artist name is kept in the album field — the widget only
    // renders title + artist, so it never shows there, and the web's
    // own album value is just the app name ("HAo Studio"), so
    // nothing meaningful is lost. No lyric line at the current
    // position (intro / outro / instrumental) -> real artist name.
    // Never touches the card when it is showing something else
    // (e.g. the native player's stream), and never writes when the
    // displayed artist already matches.
    private func syncMusicNowPlaying(line: String) {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        guard (info[MPMediaItemPropertyTitle] as? String) == title else { return }
        let desired = line.isEmpty ? artist : line
        let current = info[MPMediaItemPropertyArtist] as? String ?? ""
        if current == desired {
            lastNowPlayingArtist = desired
            return
        }
        info[MPMediaItemPropertyArtist] = desired
        if !line.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = artist
        }
        center.nowPlayingInfo = info
        lastNowPlayingArtist = desired
    }

    // Give the Now Playing artist field back to the real artist name,
    // but only if this manager had replaced it with a lyric line and
    // the card is still showing this song. Called from end() while
    // the owner is still "music".
    private func restoreMusicNowPlayingArtist() {
        guard let last = lastNowPlayingArtist, last != artist else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        guard (info[MPMediaItemPropertyTitle] as? String) == title else { return }
        guard (info[MPMediaItemPropertyArtist] as? String) == last else { return }
        info[MPMediaItemPropertyArtist] = artist
        center.nowPlayingInfo = info
        lastNowPlayingArtist = artist
    }
}
