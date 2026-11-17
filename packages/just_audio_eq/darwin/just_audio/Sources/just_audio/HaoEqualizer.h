// HaoEqualizer — HAo Studio vendored-just_audio equalizer engine.
//
// Direct ObjC port of Beans `BeansEqualizer.swift` (480 lines, read-only
// reference at ~/workspace/research/beans-music/Beans/BeansEqualizer.swift):
// a REAL 10-band equalizer, not a tone knob. One MTAudioProcessingTap per
// AVPlayerItem (kMTAudioProcessingTapCreationFlag_PostEffects) runs ten
// RBJ peaking biquads in series over the Float32 samples, per channel,
// with a preamp gain up front — the same math Beans uses.
//
// Why this lives in the vendored just_audio fork instead of the Runner:
// just_audio 0.10.6 creates its AVPlayerItem inside
// UriAudioSource.createPlayerItem (darwin, ObjC) and exposes NO handle
// to it — JustAudioPlugin keeps its players in a private `_players`
// dictionary with no accessor (JustAudioPlugin.m), and Dart has no
// AVPlayerItem API at all. A Runner-side method-channel plugin therefore
// cannot reach the player. The only place the tap can be attached is
// where the item is created, so the hook is one line in
// UriAudioSource.m (`[[HaoEqualizer shared] applyToItem:item]`).
//
// Beans mapping (line numbers are BeansEqualizer.swift):
//  - bandFrequencies [31,62,125,250,500,1000,2000,4000,8000,16000],
//    maximumGain 12, 0.5 dB steps, preamp linear = 10^(dB/20)
//    (normalizedGain / linearGain).
//  - BiquadCoefficients.peaking: RBJ peaking, alpha = sin(w)/2, clamped
//    frequency 20..sampleRate*0.45, identity when |gain| <= 0.001.
//  - Tap callbacks (init/finalize/prepare/unprepare/process) and the
//    per-channel state array (8 channels x 10 bands, clamp +-4,
//    non-finite -> 0, Float32-only guard) are transliterated 1:1.
//  - makeAudioMix -> -audioMixForTrack:; PlayerManager.configureEqualizer
//    (PlayerManager.swift:1373-1398: async "tracks" load, then set
//    item.audioMix on main, only while still enabled) -> -applyToItem:.
//
// Deliberate divergences from Beans, with reasons:
//  1. Beans has ONE player; we have TWO crossfade players (A/B). The
//     tap is attached per item at creation, so both players' items get
//     it automatically, and a weak registry of live items lets an
//     enable/disable toggle re-apply to BOTH players' current items.
//     (Beans only re-applies to player.currentItem.)
//  2. Gain/preamp changes do NOT recreate the tap: the tap callbacks
//     read the shared coefficients live under the lock (exactly as
//     Beans' process() reads processingGains/coefficients), so a slider
//     drag retunes the running audio with no glitch. Only the enabled
//     flag needs a re-apply (set/clear audioMix on live items).
//  3. No 5-band legacy migration (Beans normalizedGains): we never
//     shipped a 5-band EQ, so there is no legacy data to migrate.
//  4. No UserDefaults persistence here: Dart (EqualizerStore, Hive)
//     owns persistence and pushes settings over the
//     `com.haostudio.standalone/equalizer` method channel
//     (updateSettings). This singleton only holds the live DSP state.
//
// Threading: updateSettings runs on the Flutter main thread; the tap
// process callback runs on a realtime audio thread and reads shared
// state under _lock, exactly like Beans' configurationLock.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HaoEqualizer : NSObject

+ (instancetype)shared;

/// Push live settings from Dart (enabled, 10 gains in dB, preamp in dB).
/// Gains outside -12..+12 are clamped and rounded to 0.5 dB steps,
/// exactly like Beans normalizedGain. Only an enabled-flag change
/// re-applies audioMix to live items; gain/preamp changes are picked
/// up live by the running taps.
- (void)updateSettingsWithEnabled:(BOOL)enabled
                            gains:(nullable NSArray<NSNumber *> *)gains
                           preamp:(double)preamp;

/// Attach the EQ tap to an AVPlayerItem (or clear it when disabled).
/// Mirrors Beans PlayerManager.configureEqualizer: the audio track is
/// loaded asynchronously and audioMix is set on the main thread only
/// while the item is still alive and EQ is still enabled. Safe to call
/// on a fresh item (createPlayerItem) and on a live item (re-apply).
- (void)applyToItem:(AVPlayerItem *)item;

@end

NS_ASSUME_NONNULL_END
