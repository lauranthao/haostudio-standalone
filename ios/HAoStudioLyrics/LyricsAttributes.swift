import ActivityKit
import Foundation

// Shared Live Activity attributes for synced lyrics (lock screen +
// Dynamic Island). This file is compiled into BOTH the app target and
// the HAoStudioLyrics widget extension target, so the app and the
// extension agree on the activity's shape. The struct is gated to
// iOS 16.2 because the ActivityKit calls this feature uses
// (request with pushType, end with dismissalPolicy) need 16.2;
// the main app still deploys to iOS 15.0.
@available(iOS 16.2, *)
public struct LyricsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // The lyric line for the current playback position.
        public var line: String
        // Whether playback is currently playing (vs paused).
        public var isPlaying: Bool

        public init(line: String, isPlaying: Bool) {
            self.line = line
            self.isPlaying = isPlaying
        }
    }

    // Song / episode title. Static for the activity's lifetime.
    public var title: String
    // Artist (music) or platform (live / VOD).
    public var artist: String

    public init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}
