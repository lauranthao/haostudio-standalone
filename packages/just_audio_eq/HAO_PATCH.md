# just_audio vendored fork — HAo Studio equalizer patch

Vendored copy of `just_audio 0.10.6` (pristine source:
`~/.pub-cache/hosted/pub.dev/just_audio-0.10.6`), pinned by a `path:`
dependency in the app pubspec. `example/` and `test/` were removed;
`lib/` (Dart) and `android/` are byte-identical to 0.10.6. Only the
`darwin/` iOS/macOS layer is patched, for one reason: the 10-band
equalizer needs an `MTAudioProcessingTap` on the `AVPlayerItem`, and
just_audio exposes no handle to it (see below).

## Why a fork, and why not a Runner plugin

- `UriAudioSource.createPlayerItem` is the ONLY place just_audio creates
  an `AVPlayerItem` (`darwin/.../UriAudioSource.m`).
- `JustAudioPlugin` keeps its players in a private `_players` dictionary
  with no accessor (`JustAudioPlugin.m`: only `init` / `disposePlayer` /
  `disposeAllPlayers`); `AudioPlayer.h` exposes the `AVQueuePlayer` but
  there is no registry to reach `AudioPlayer` instances from another
  plugin. A Runner-side method-channel plugin therefore cannot reach the
  player — verified by reading the plugin source, not assumed.
- A runtime swizzle of `AVPlayerItem` init was rejected: it is global
  and would also hit video `AVPlayerItem`s, and it is fragile across
  iOS versions.
- Rewriting music playback on a bespoke native player was rejected:
  it would re-implement crossfade, position/error streams, seek/rate
  and the kill-saved progress path — a large regression surface for no
  benefit. The fork keeps every Dart call site unchanged
  (`import 'package:just_audio/just_audio.dart'` still resolves).

## Patch list (all other files identical to 0.10.6)

1. **New: `darwin/just_audio/Sources/just_audio/HaoEqualizer.h/.m`**
   ObjC port of Beans `BeansEqualizer.swift` (480 lines): 10-band RBJ
   peaking biquads over an `MTAudioProcessingTap`
   (`kMTAudioProcessingTapCreationFlag_PostEffects`), per-channel state
   (8 channels x 10 bands), preamp, Float32-only guard, clamp ±4.
   Picked up automatically by the podspec glob
   `just_audio/Sources/just_audio/**/*.{h,m}`.
2. **`UriAudioSource.m` — one hook line** in `createPlayerItem`, after
   the item is built: `[[HaoEqualizer shared] applyToItem:item];`
   Covers every item just_audio makes: both A/B crossfade players, the
   gapless `playerItem2` (`preparePlayerItem2` re-calls
   `createPlayerItem`), file:// and http(s) URLs.
3. **`JustAudioPlugin.m` — one method channel**
   `com.haostudio.standalone/equalizer`, method `updateSettings`
   `{enabled, gains[10], preamp}` -> `HaoEqualizer` singleton. Same
   plugin instance handles both channels; method names do not collide.
4. **`just_audio.podspec` — `s.frameworks = 'AVFoundation', 'MediaToolbox'`**
   (upstream lists neither; the tap symbols live in MediaToolbox).
5. **Build #8 fix (2026-11-18): `MTAudioProcessingTap` -> `MTAudioProcessingTapRef`**
   in `HaoEqualizer.m` (11 sites: tap callbacks + local). Beans is Swift,
   where the type is `MTAudioProcessingTap`; in ObjC the type is
   `MTAudioProcessingTapRef` only — the Swift name does not exist, and
   Xcode failed the build with "Unknown type name 'MTAudioProcessingTap'".
   The `audioTapProcessor` selector error in the same build was a
   knock-on of the unknown type. Lesson: Swift->ObjC ports must use the
   `Ref` CF type names, never the Swift-renamed ones.
6. **Build #10 fix (2026-11-18): `[[... alloc] initWithTrack:track]` ->
   `[AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track]`**
   in `audioMixForTrack:`. Build #10 (with the Ref fix in) failed with
   "No visible @interface ... declares the selector 'initWithTrack:'" —
   the instance initializer is not visible to the ObjC compiler in the
   current SDK, while the `audioMixInputParametersWithTrack:` class
   factory is the canonical documented constructor (Apple sample code
   and every ObjC tutorial use it). Build #10's log had no other error,
   so `audioTapProcessor` resolves fine once the type is right.
7. **Forward-buffer default (2026-11-18, playback audit): `UriAudioSource.m`
   `createPlayerItem` sets `item.preferredForwardBufferDuration = 10.0`
   for REMOTE http(s) items when no value was configured.** The app
   constructs `AudioPlayer()` with no `audioLoadConfiguration`, so
   `LoadControl.preferredForwardBufferDuration` arrives as `NSNull` and
   upstream leaves the property at 0 (system chooses — small on
   progressive download); network songs stalled mid-track and at
   crossfade start. This is the upstream mechanism
   (`DarwinLoadControl.preferredForwardBufferDuration`, Dart `Duration`
   -> microseconds over the channel -> `/1000/1000.0` seconds), not a
   per-song method channel: the value is set once at item creation,
   the only place just_audio makes an `AVPlayerItem`, so it covers
   both A/B crossfade players and gapless `playerItem2`. An explicit
   `DarwinLoadControl` value still wins (including an explicit 0);
   `file://` items are untouched. 10 s basis: ~400 KB at 320 kbps,
   ~1.25 MB at lossless ~1 Mbps per item; covers multi-second CDN
   hiccups without the start delay / skipped-bytes waste of 30-60 s.
   Constant: `HaoDefaultForwardBufferDurationSeconds` at the top of
   `UriAudioSource.m`. If the app ever passes an explicit
   `AudioLoadConfiguration(darwinLoadControl:
   DarwinLoadControl(preferredForwardBufferDuration: ...))` at
   `AudioPlayer()` construction, that value takes over and this
   default becomes inert.
8. **Per-tap DSP state isolation (2026-11-22, 1.1.6): `HaoEqualizer.m`
   only.** Filter memory (`filterZ1`/`filterZ2`), sample rate,
   Float32-ness and coefficients moved out of the singleton into a
   per-tap struct (`HaoEqualizerTapState`, inside `HaoEqualizerTapStorage`
   allocated in `TapInit`, freed in `TapFinalize`). `TapPrepare` now
   resets ONLY its own tap's state and rebuilds ONLY its own
   coefficients; `TapProcess` reads/writes ONLY its own tap's state.
   The singleton keeps only the shared settings (enabled / gains /
   preamp) plus a `_gainsVersion` counter: a slider drag bumps the
   version and each running tap rebuilds its own coefficient snapshot
   (at its own sample rate) on its next process call, so live retune
   still works with no tap recreation. Why: A/B crossfade runs two
   taps concurrently (2.5 s overlap) and the old shared state let one
   tap's prepare zero the other's running filter memory and let two
   sample rates cross-contaminate (audible click risk at every auto
   track change). Filter math itself is unchanged (same RBJ peaking,
   same 10 bands, same gains). Note: the Behaviour-contract sentence
   below ("reads shared coefficients under a lock") now means each tap
   keeps its own coefficient snapshot, refreshed from the shared gains
   when `_gainsVersion` moves.
9. **Tap loudness measurement (2026-11-22, 1.1.6): `HaoEqualizer.m` /
   `HaoEqualizer.h` / `JustAudioPlugin.m`.** Per-tap RMS accumulators
   (`loudnessSumSquares` / `loudnessSamples` / `loudnessFrames` in
   `HaoEqualizerTapState` — same per-tap isolation as item 8, so two
   crossfade taps never mix measurements). `processBufferList:`
   accumulates the RAW source sample (before preamp/EQ — loudness is
   a property of the track, not of the user's EQ preset): one
   multiply-add per sample, no extra pass, no allocation. At
   `TapFinalize` the tap reports once: RMS -> dBFS + 3.0 dB fixed
   offset as a LUFS APPROXIMATION (no K-weighting, no ffmpeg /
   loudnorm, no GPL/AGPL — see `HaoEqualizer.m` constants; offset
   and the 10 s minimum are 待确认, calibrate on device). < 10 s of
   audio, silence, or a missing stamp/handler reports nothing.
   Attribution: Dart pushes the track's identityKey via the
   equalizer channel (`setTrackKey`, handled in `JustAudioPlugin.m`)
   immediately before every open (`_openOn`, `_crossfadeTo`) and
   every preload (`_prefetchNext` — the preload creates the item
   before that track's `_loadCurrent` runs, so stamping only in
   `_loadCurrent` would arrive too late); `audioMixForTrack:`
   records the pending key per tap pointer and finalize looks it up.
   Reports travel native -> Dart on the same channel
   (`loudnessMeasured` {identityKey, lufs}, handler set by
   `JustAudioPlugin` at registration, dispatched to main by
   `HaoEqualizer`); Dart side is `EqualizerStore.onLoudnessMeasured`
   -> `MusicPlayerController.noteMeasuredLoudness` -> Hive cache
   `musicLoudnessCache`. Known limitation: the tap only exists while
   EQ is on, so EQ-off tracks are never measured (normalisation
   measurement depends on the EQ tap existing); the switch itself
   still works from the second play of any track measured while EQ
   was on.

## Behaviour contract (what Dart relies on)

- Settings pushed before any playback are stored in the singleton and
  applied to every item created afterwards (creation-time hook).
- Gain/preamp changes retune RUNNING taps live (the process callback
  reads shared coefficients under a lock, as Beans does); no tap is
  recreated on a slider drag.
- An enabled-flag change re-applies `audioMix` (set/clear) to all live
  items via a weak registry, so BOTH crossfade players are covered.
- EQ is iOS/macOS only (the `darwin` layer). On Android the Dart
  channel call throws `MissingPluginException`, caught in Dart — the
  store still persists and the UI still works, but there is no audio
  effect. The music chain is AVPlayer (`just_audio`) on iOS, so this
  matches the feature's scope; Beans itself is iOS-only.
- Loudness: a tap that measured >= 10 s of audio reports once at
  finalize (`loudnessMeasured` {identityKey, lufs}, RMS-approximated
  LUFS — NOT precise LUFS); shorter listens, silence, and EQ-off
  tracks report nothing. Dart stamps each tap via `setTrackKey`
  immediately before the open / preload that creates its item.

## Maintenance

- To take a newer just_audio: copy the new version over this directory,
  re-apply the three items above (they are small and commented with
  `HAo equalizer hook`), re-run `test/equalizer_store_test.dart` and
  the music regression set. Do NOT `flutter pub upgrade just_audio`
  expecting the patch to survive — a hosted version would overwrite it.
