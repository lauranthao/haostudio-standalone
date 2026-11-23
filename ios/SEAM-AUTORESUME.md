# SEAM — Auto-resume position (music)

Branch: `feature/swift-2.0-autoresume` (base: wiring @ 083c38e).
Decision (chen 2026-11-23): save the music position every 10 s
while playing + on pause + on entering background, local only.
"Only save when killed" is not implementable on iOS: a
backgrounded app is suspended and can be killed with no callback
(`applicationWillTerminate` only fires while still running in
the background). Loss on kill is at most ~10 s.

## Storage (no new keys)

- Same store as before: `MusicLibraryStore` collection
  `musicResume` (`[identityKey: seconds]`), via the existing
  `saveResume(_:seconds:)` / `resumeSeconds(for:)`.
- New: `MusicLibraryStore.clearResume(_:)` — removes one key,
  no-op (no rewrite) when absent.
- Nothing leaves the device; nothing goes to Keychain (no secret).

## Rules (`MusicResumeLogic`, pure, AppCore, tested)

- Periodic gate: playing + position >= 1 s + >= 10 s since the
  last write + moved >= 5 s since the last write (a track
  change always counts as a move). Worst case ~6 small rewrites
  per minute of playback.
- Immediate save (pause / background): same, minus the 10 s
  interval; an identical (key, seconds) checkpoint is skipped.
- Restore validation: stored > 0, and when the duration is
  known, stored < duration - 5 s. At/past the end = finished,
  start from 0.
- End positions are never written (the writer also refuses
  seconds >= duration - 1).

## Wiring (`MusicPlayerViewModel`, @MainActor)

- Init (autoResume on): reads the stored checkpoint for the
  restored song into `pendingResume`; `startPlayback()` is
  unchanged (the player has no start-position parameter).
- `player.$duration` sink: once duration > 0 and the current
  song still matches `pendingResume.key`, seeks once to the
  validated position, then clears the pending value. Song
  changed / load failed / invalid = dropped, starts from 0.
- `player.$position` sink: periodic checkpoint (fresh player
  position, not the scrub-frozen mirror).
- `player.$isPlaying` sink: pause (not a natural completion)
  saves now.
- `HAoStudioApp` scenePhase `.background`: `musicPlayer.saveResumeNow()`.
- Natural completion (`noteNaturalCompletion`): clears the
  checkpoint for that song (next play starts from 0) and drops
  a pending launch seek for it.
- Manual `seek(to:)` clears a pending launch seek (user wins).

## Tests

- `Tests/SettingsTests/MusicResumeLogicTests.swift`: 17 tests,
  pure logic only (gate timing, move threshold, track change,
  immediate-save dedup, restore validation incl. end/unknown
  duration, save→restore round trip). Unrun (no Swift toolchain).
- The view-model wiring itself has no test (the VM init restores
  a real queue and schedules real playback); it is verified by
  reading + preflight only — same treatment as other iOS-only
  wiring this slice.

## Known limits

- Uncompiled, tests unrun (no Swift toolchain on the VM).
- The periodic saver rewrites the whole resume map file each
  time it fires (the existing `saveResume` API is read-modify-
  write); the map is `[String: Int]`, small, and writes are
  gated to ~6/min worst case.
- A checkpoint survives an app update (same collection file);
  a checkpoint for a song whose file/URL is gone is validated
  by duration at apply time and dropped.
