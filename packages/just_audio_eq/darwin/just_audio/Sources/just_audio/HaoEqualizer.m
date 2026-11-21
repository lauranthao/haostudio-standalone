// HaoEqualizer — ObjC port of Beans `BeansEqualizer.swift`.
// See HaoEqualizer.h for the Beans mapping and the deliberate divergences.
#import "HaoEqualizer.h"

#import <MediaToolbox/MediaToolbox.h>
#import <math.h>

static const double HaoBandFrequencies[10] = {
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
};
static const double HaoMaximumGain = 12.0;
static const NSUInteger HaoMaximumChannels = 8;

// Loudness measurement (1.1.6 normalisation feed-in, strategy A):
// RMS -> dBFS plus a fixed offset as a LUFS approximation.
// K-weighting is NOT applied (no filter budget on the realtime
// thread, no loudnorm library — ffmpeg / GPL / AGPL is banned):
// the offset is a rough average for music, so the reported value is
// an APPROXIMATION, good enough for attenuation-only normalisation
// (a few dB of error only moves the cut a little, never boosts).
// Both numbers are 待确认 — calibrate on device against tracks of
// known loudness (see the report for this wiring round).
static const double HaoLoudnessRmsToLufsOffsetDb = 3.0;
static const double HaoLoudnessMinSeconds = 10.0;

// One biquad section. Beans BiquadCoefficients (b0 b1 b2 a1 a2).
typedef struct {
    float b0, b1, b2, a1, a2;
} HaoBiquad;

// Per-tap DSP state. A/B crossfade runs two MTAudioProcessingTaps
// concurrently (2.5 s overlap), so filter memory, sample rate and
// coefficients must live in the tap's own storage — NEVER in the
// singleton. The singleton only keeps the shared settings (enabled /
// gains / preamp) that every tap reads as a snapshot under _lock;
// each tap's z1/z2 and coefficients are private to that tap, so one
// tap's prepare() can never zero the other tap's running state and
// two sample rates can never cross-contaminate.
typedef struct {
    double sampleRate;
    BOOL formatIsFloat32;
    HaoBiquad coefficients[10];
    // Beans filterStates: 80 = 8 channels x 10 bands, z1/z2 per section.
    float filterZ1[8 * 10];
    float filterZ2[8 * 10];
    // Last _gainsVersion this tap built its coefficients from; a
    // mismatch means a slider drag moved the gains and this tap must
    // rebuild from the shared _gains on its next process call.
    uint64_t coefficientsVersion;
    // Loudness accumulators (1.1.6 normalisation feed-in). Per-tap,
    // like the filter state above: A/B crossfade runs two taps at
    // once and their measurements must never mix. Only O(1) work
    // happens on the realtime thread — one multiply-add per sample
    // (see processBufferList:); the dB math runs once, in finalize.
    // loudnessSamples counts every processed sample (all channels);
    // loudnessFrames counts frames once per buffer (first buffer
    // only, so interleaved and deinterleaved layouts agree) and is
    // the >= 10 s trust gate in finalize.
    double loudnessSumSquares;
    uint64_t loudnessSamples;
    uint64_t loudnessFrames;
} HaoEqualizerTapState;

// Tap storage: the owning singleton (unretained — it lives for the
// app lifetime, same guarantee as the clientInfo in audioMixForTrack:)
// plus this tap's private DSP state. Allocated in TapInit, freed in
// TapFinalize.
typedef struct {
    HaoEqualizer *equalizer;
    HaoEqualizerTapState dsp;
} HaoEqualizerTapStorage;

// RBJ peaking EQ. BeansEqualizer.swift BiquadCoefficients.peaking,
// transliterated literally (alpha = sin(omega)/2, frequency clamped
// 20..sampleRate*0.45, identity when |gain| <= 0.001).
static HaoBiquad HaoBiquadPeaking(double frequency, double gain,
                                  double sampleRate) {
    HaoBiquad identity = {1, 0, 0, 0, 0};
    if (fabs(gain) <= 0.001) return identity;
    double clampedFrequency = fmin(fmax(frequency, 20), sampleRate * 0.45);
    double amplitude = pow(10, gain / 40);
    double omega = 2 * M_PI * clampedFrequency / sampleRate;
    double alpha = sin(omega) / 2;
    double cosine = cos(omega);
    double b0 = 1 + alpha * amplitude;
    double b1 = -2 * cosine;
    double b2 = 1 - alpha * amplitude;
    double a0 = 1 + alpha / amplitude;
    double a1 = -2 * cosine;
    double a2 = 1 - alpha / amplitude;
    HaoBiquad out = {(float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0),
                     (float)(a1 / a0), (float)(a2 / a0)};
    return out;
}

// Beans normalizedGain: clamp +-12, round to 0.5 dB steps.
static double HaoNormalizedGain(double value) {
    double clamped = fmin(fmax(value, -HaoMaximumGain), HaoMaximumGain);
    return round(clamped * 2) / 2;
}

static float HaoLinearGain(double gainDb) {
    return (float)pow(10, gainDb / 20);
}

static void HaoEqualizerTapInit(MTAudioProcessingTapRef tap,
                                void *clientInfo, void **tapStorageOut);
static void HaoEqualizerTapFinalize(MTAudioProcessingTapRef tap);
static void HaoEqualizerTapPrepare(MTAudioProcessingTapRef tap,
                                   CMItemCount maxFrames,
                                   const AudioStreamBasicDescription *processingFormat);
static void HaoEqualizerTapUnprepare(MTAudioProcessingTapRef tap);
static void HaoEqualizerTapProcess(MTAudioProcessingTapRef tap,
                                   CMItemCount numberFrames,
                                   MTAudioProcessingTapFlags flags,
                                   AudioBufferList *bufferListInOut,
                                   CMItemCount *numberFramesOut,
                                   MTAudioProcessingTapFlags *flagsOut);

@implementation HaoEqualizer {
    NSLock *_lock;
    BOOL _enabled;
    double _gains[10];
    double _preampDb;
    // Shared live settings, read by every tap's process callback under
    // _lock. Per-tap DSP state (sample rate, Float32-ness, coefficients,
    // filter z1/z2) lives in HaoEqualizerTapStorage, NOT here — A/B
    // crossfade runs two taps at once and they must never share it.
    // Beans: processingEnabled / processingGains / processingPreampLinear.
    BOOL _processingEnabled;
    float _processingPreampLinear;
    // Bumped whenever _gains changes; each tap rebuilds its own
    // coefficients from _gains when its snapshot version lags.
    uint64_t _gainsVersion;
    // Weak registry of every AVPlayerItem created while this engine
    // lives (both crossfade players, gapless playerItem2 included).
    // Lets an enable/disable toggle re-apply audioMix to live items
    // without knowing which just_audio player owns them.
    NSHashTable<AVPlayerItem *> *_liveItems;
    // Pending identityKey for the next tap(s) to be created (pushed
    // by Dart via -setPendingTrackKey: immediately before an open /
    // preload), and the per-tap stamp recorded at tap creation
    // (tap pointer -> identityKey), removed at finalize. The stamp
    // is what attributes a finalize loudness report to its track.
    NSString *_pendingTrackKey;
    NSMutableDictionary<NSNumber *, NSString *> *_tapTrackKeys;
}

@synthesize loudnessReportHandler = _loudnessReportHandler;

+ (instancetype)shared {
    static HaoEqualizer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HaoEqualizer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _enabled = NO;
        _preampDb = 0;
        _processingEnabled = NO;
        _processingPreampLinear = 1;
        _gainsVersion = 0;
        for (int i = 0; i < 10; i++) {
            _gains[i] = 0;
        }
        _liveItems = [NSHashTable weakObjectsHashTable];
        _tapTrackKeys = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)updateSettingsWithEnabled:(BOOL)enabled
                            gains:(nullable NSArray<NSNumber *> *)gains
                           preamp:(double)preamp {
    BOOL enabledChanged;
    [_lock lock];
    enabledChanged = (_enabled != enabled);
    _enabled = enabled;
    _processingEnabled = enabled;
    if (gains != nil) {
        for (int i = 0; i < 10; i++) {
            double value = i < (int)gains.count
                ? [gains[i] doubleValue] : 0;
            _gains[i] = HaoNormalizedGain(value);
        }
        // No eager coefficient rebuild: each live tap rebuilds its own
        // snapshot from _gains when it sees _gainsVersion move.
        _gainsVersion++;
    }
    _preampDb = HaoNormalizedGain(preamp);
    _processingPreampLinear = HaoLinearGain(_preampDb);
    [_lock unlock];
    // Gain/preamp changes are picked up live by running taps: each tap
    // rebuilds its own coefficients from _gains when it sees
    // _gainsVersion move (no tap is recreated on a slider drag). Only
    // an enabled-flag change needs audioMix set/cleared on live items.
    if (enabledChanged) {
        [self reapplyToLiveItems];
    }
}

// Stamp the next created tap(s) with this track's identityKey (see
// HaoEqualizer.h). Empty keys clear the stamp; the stamp is sticky
// (last push wins) until the next push replaces it.
- (void)setPendingTrackKey:(nullable NSString *)identityKey {
    [_lock lock];
    _pendingTrackKey = identityKey.length > 0
        ? [identityKey copy] : nil;
    [_lock unlock];
}

- (void)applyToItem:(AVPlayerItem *)item {
    if (item == nil) return;
    [_lock lock];
    [_liveItems addObject:item];
    BOOL shouldProcess = _processingEnabled;
    [_lock unlock];
    if (!shouldProcess) {
        // Beans configureEqualizer: disabled -> item.audioMix = nil.
        // audioMix is main-thread state; never touch it from a
        // background load callback.
        if ([NSThread isMainThread]) {
            item.audioMix = nil;
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                item.audioMix = nil;
            });
        }
        return;
    }
    // Beans configureEqualizer: load "tracks" async, then set the mix
    // on main only while the item is still alive and EQ still on.
    AVAsset *asset = item.asset;
    __weak AVPlayerItem *weakItem = item;
    __weak HaoEqualizer *weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"]
                         completionHandler:^{
        HaoEqualizer *strongSelf = weakSelf;
        AVPlayerItem *strongItem = weakItem;
        if (strongSelf == nil || strongItem == nil) return;
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] !=
            AVKeyValueStatusLoaded) {
            return;
        }
        AVAssetTrack *track =
            [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (track == nil) return;
        AVAudioMix *mix = [strongSelf audioMixForTrack:track];
        if (mix == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Item may have been disposed or EQ switched off while
            // the track loaded; both make the mix stale.
            if (weakItem == nil || ![strongSelf isEnabled]) return;
            // Only set when this item is still a live item (it is
            // weakly registered at creation; a deallocated item
            // drops out of _liveItems on its own).
            strongItem.audioMix = mix;
        });
    }];
}

- (BOOL)isEnabled {
    [_lock lock];
    BOOL enabled = _enabled;
    [_lock unlock];
    return enabled;
}

// MARK: - Private

- (void)rebuildCoefficientsLockedForState:(HaoEqualizerTapState *)state {
    for (int i = 0; i < 10; i++) {
        state->coefficients[i] = HaoBiquadPeaking(HaoBandFrequencies[i],
                                                  _gains[i],
                                                  state->sampleRate);
    }
}

- (void)reapplyToLiveItems {
    NSArray<AVPlayerItem *> *items;
    [_lock lock];
    items = [_liveItems allObjects];
    [_lock unlock];
    for (AVPlayerItem *item in items) {
        [self applyToItem:item];
    }
}

// Beans makeAudioMix(for:): one PostEffects tap per track, wrapped in
// an AVMutableAudioMix. Returns nil when EQ is off or tap creation
// fails. The singleton lives for the app lifetime, so the tap's
// unretained clientInfo (self) is stable — same as Beans'
// Unmanaged.passUnretained(self).
- (nullable AVAudioMix *)audioMixForTrack:(AVAssetTrack *)track {
    [_lock lock];
    BOOL shouldProcess = _processingEnabled;
    [_lock unlock];
    if (!shouldProcess) return nil;

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge void *)self;
    callbacks.init = HaoEqualizerTapInit;
    callbacks.finalize = HaoEqualizerTapFinalize;
    callbacks.prepare = HaoEqualizerTapPrepare;
    callbacks.unprepare = HaoEqualizerTapUnprepare;
    callbacks.process = HaoEqualizerTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(
        kCFAllocatorDefault, &callbacks,
        kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    if (status != noErr || tap == NULL) {
        NSLog(@"[HaoEqualizer] tap creation failed: %d", (int)status);
        return nil;
    }
    // Stamp this tap with the pending track key (see
    // -setPendingTrackKey:): the finalize report is attributed by
    // this stamp, so two concurrent crossfade taps never mix their
    // measurements up. Recorded synchronously here — the tap cannot
    // process (and its init cannot run) before the mix is attached
    // to the item, which happens after this returns.
    [_lock lock];
    if (_pendingTrackKey != nil) {
        _tapTrackKeys[@((uintptr_t)tap)] = _pendingTrackKey;
    }
    [_lock unlock];
    AVMutableAudioMixInputParameters *params =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    params.audioTapProcessor = tap;
    // audioTapProcessor retains the tap; release our create reference.
    CFRelease(tap);
    AVMutableAudioMix *mix = [[AVMutableAudioMix alloc] init];
    mix.inputParameters = @[params];
    return mix;
}

// Beans prepare(with:): capture this tap's sample rate + Float32-ness,
// reset ONLY this tap's filter state, rebuild ONLY this tap's
// coefficients for the real sample rate. Other taps keep running
// untouched — prepare must never zero a sibling tap's state.
- (void)prepareTapState:(HaoEqualizerTapState *)state
            withFormat:(const AudioStreamBasicDescription *)format {
    [_lock lock];
    state->sampleRate = fmax(format->mSampleRate, 8000);
    state->formatIsFloat32 =
        format->mFormatID == kAudioFormatLinearPCM &&
        format->mBitsPerChannel == 32 &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    memset(state->filterZ1, 0, sizeof(state->filterZ1));
    memset(state->filterZ2, 0, sizeof(state->filterZ2));
    [self rebuildCoefficientsLockedForState:state];
    state->coefficientsVersion = _gainsVersion;
    [_lock unlock];
}

// Beans process(bufferList:frameCount:), transliterated: preamp, then
// the 10 biquads in series per sample per channel, clamp +-4,
// non-finite -> 0. Runs on the realtime audio thread. Filter memory
// and coefficients come from THIS tap's own storage (tapState), so two
// concurrent taps never share them; only the shared settings
// (enabled / preamp / gains) are read under _lock, exactly like
// Beans' configurationLock.
- (void)processBufferList:(AudioBufferList *)bufferList
               frameCount:(NSInteger)frameCount
                 tapState:(HaoEqualizerTapState *)state {
    if (frameCount <= 0) return;
    [_lock lock];
    if (!_processingEnabled || !state->formatIsFloat32) {
        [_lock unlock];
        return;
    }
    float preampLinear = _processingPreampLinear;
    // A slider drag moved the shared gains since this tap last built
    // its coefficients: rebuild this tap's snapshot (at its own sample
    // rate), so a live retune never touches the other tap.
    if (state->coefficientsVersion != _gainsVersion) {
        [self rebuildCoefficientsLockedForState:state];
        state->coefficientsVersion = _gainsVersion;
    }
    HaoBiquad coefficients[10];
    memcpy(coefficients, state->coefficients, sizeof(coefficients));
    // Copy state out is NOT done: filter state must persist across
    // calls, so it is updated in place below under the same lock.
    // (Beans holds the same lock for the whole process call.)
    NSInteger firstChannelIndex = 0;
    for (UInt32 b = 0; b < bufferList->mNumberBuffers; b++) {
        AudioBuffer buffer = bufferList->mBuffers[b];
        NSInteger channelCount = buffer.mNumberChannels > 0
            ? (NSInteger)buffer.mNumberChannels : 1;
        if (buffer.mData == NULL) {
            firstChannelIndex += channelCount;
            continue;
        }
        float *samples = (float *)buffer.mData;
        NSInteger availableFrames = (NSInteger)buffer.mDataByteSize /
            (NSInteger)(sizeof(float) * (size_t)channelCount);
        NSInteger framesToProcess = MIN(frameCount, availableFrames);
        for (NSInteger channelOffset = 0; channelOffset < channelCount;
             channelOffset++) {
            NSInteger channel = MIN(firstChannelIndex + channelOffset,
                                    (NSInteger)HaoMaximumChannels - 1);
            NSInteger stateOffset = channel * 10;
            for (NSInteger frame = 0; frame < framesToProcess; frame++) {
                NSInteger sampleIndex = frame * channelCount + channelOffset;
                // Loudness (1.1.6 normalisation feed-in): accumulate
                // the RAW source sample — before preamp/EQ, so the
                // measurement is a property of the track, not of the
                // user's EQ preset (a bass boost must not inflate
                // loudness and fight the normalisation). One
                // multiply-add per sample: no extra pass, no
                // allocation, no lock beyond the one already held
                // for this process call.
                float rawSample = samples[sampleIndex];
                state->loudnessSumSquares +=
                    (double)rawSample * (double)rawSample;
                state->loudnessSamples += 1;
                float sample = rawSample * preampLinear;
                for (int bandIndex = 0; bandIndex < 10; bandIndex++) {
                    NSInteger stateIndex = stateOffset + bandIndex;
                    HaoBiquad coefficient = coefficients[bandIndex];
                    float z1 = state->filterZ1[stateIndex];
                    float z2 = state->filterZ2[stateIndex];
                    float filtered = coefficient.b0 * sample + z1;
                    z1 = coefficient.b1 * sample -
                        coefficient.a1 * filtered + z2;
                    z2 = coefficient.b2 * sample -
                        coefficient.a2 * filtered;
                    state->filterZ1[stateIndex] = z1;
                    state->filterZ2[stateIndex] = z2;
                    sample = filtered;
                }
                samples[sampleIndex] =
                    isfinite(sample) ? fminf(fmaxf(sample, -4), 4) : 0;
            }
        }
        // Frames are counted once per buffer (first buffer only):
        // in an interleaved layout there is one buffer, in a
        // deinterleaved layout one buffer per channel — either way
        // the first buffer holds exactly one channel's frames.
        if (b == 0) {
            state->loudnessFrames += (uint64_t)framesToProcess;
        }
        firstChannelIndex += channelCount;
    }
    [_lock unlock];
}

// Read this tap's loudness accumulators + stamped track key,
// compute the RMS-approximated LUFS and hand it to the report
// handler on the main thread. Called from TapFinalize (tap-teardown
// thread — NOT main, NOT realtime): only cheap math + one dispatch
// happen here; the method-channel invoke runs on main. Reports once
// per tap (whole track heard so far): a skip mid-track still yields
// a value for the portion heard, a < 10 s listen is too short to
// trust and is dropped, silence reports nothing. EQ-off tracks have
// no tap at all, so they never report (known limitation — see the
// wiring report; normalisation measurement depends on the EQ tap
// existing).
- (void)finalizeLoudnessForTap:(MTAudioProcessingTapRef)tap
                      tapState:(HaoEqualizerTapState *)state {
    NSString *identityKey = nil;
    double sumSquares = 0;
    uint64_t samples = 0;
    uint64_t frames = 0;
    double sampleRate = 44100;
    void (^handler)(NSString *, double) = nil;
    [_lock lock];
    identityKey = _tapTrackKeys[@((uintptr_t)tap)];
    if (identityKey != nil) {
        [_tapTrackKeys removeObjectForKey:@((uintptr_t)tap)];
    }
    sumSquares = state->loudnessSumSquares;
    samples = state->loudnessSamples;
    frames = state->loudnessFrames;
    sampleRate = state->sampleRate;
    handler = _loudnessReportHandler;
    [_lock unlock];
    if (identityKey == nil || handler == nil) return;
    if (samples == 0) return;
    if ((double)frames < HaoLoudnessMinSeconds * sampleRate) return;
    double meanSquare = sumSquares / (double)samples;
    if (!(meanSquare > 0)) return; // silence (or non-finite input)
    double lufs = 10 * log10(meanSquare) + HaoLoudnessRmsToLufsOffsetDb;
    if (!isfinite(lufs)) return;
    // Same clamp as Dart noteMeasuredLoudness (-70..0).
    lufs = fmin(fmax(lufs, -70), 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(identityKey, lufs);
    });
}

@end

// MARK: - Tap callbacks (C functions, Beans equalizerTap*)

static void HaoEqualizerTapInit(MTAudioProcessingTapRef tap,
                                void *clientInfo, void **tapStorageOut) {
    (void)tap;
    HaoEqualizerTapStorage *storage =
        calloc(1, sizeof(HaoEqualizerTapStorage));
    if (storage == NULL) {
        *tapStorageOut = NULL;
        return;
    }
    // Unretained: the singleton lives for the app lifetime (see
    // audioMixForTrack:), so this pointer stays valid until finalize.
    storage->equalizer = (__bridge HaoEqualizer *)clientInfo;
    storage->dsp.sampleRate = 44100;
    for (int i = 0; i < 10; i++) {
        storage->dsp.coefficients[i] = (HaoBiquad){1, 0, 0, 0, 0};
    }
    *tapStorageOut = storage;
}

static void HaoEqualizerTapFinalize(MTAudioProcessingTapRef tap) {
    HaoEqualizerTapStorage *storage = MTAudioProcessingTapGetStorage(tap);
    // Report this tap's loudness BEFORE freeing its storage (the
    // accumulators live in it). Runs on the tap-teardown thread;
    // the method itself only copies numbers under the lock and
    // dispatches the report to main.
    if (storage != NULL && storage->equalizer != nil) {
        [storage->equalizer finalizeLoudnessForTap:tap
                                          tapState:&storage->dsp];
    }
    free(storage);
}

static void HaoEqualizerTapPrepare(MTAudioProcessingTapRef tap,
                                   CMItemCount maxFrames,
                                   const AudioStreamBasicDescription *processingFormat) {
    (void)maxFrames;
    HaoEqualizerTapStorage *storage = MTAudioProcessingTapGetStorage(tap);
    if (storage == NULL || storage->equalizer == nil) return;
    [storage->equalizer prepareTapState:&storage->dsp
                            withFormat:processingFormat];
}

static void HaoEqualizerTapUnprepare(MTAudioProcessingTapRef tap) {
    (void)tap;
}

static void HaoEqualizerTapProcess(MTAudioProcessingTapRef tap,
                                   CMItemCount numberFrames,
                                   MTAudioProcessingTapFlags flags,
                                   AudioBufferList *bufferListInOut,
                                   CMItemCount *numberFramesOut,
                                   MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    MTAudioProcessingTapFlags sourceFlags = 0;
    CMItemCount sourceFrames = 0;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, &sourceFlags, NULL,
        &sourceFrames);
    if (status != noErr) {
        *numberFramesOut = 0;
        *flagsOut = sourceFlags;
        return;
    }
    *numberFramesOut = sourceFrames;
    *flagsOut = sourceFlags;
    HaoEqualizerTapStorage *storage = MTAudioProcessingTapGetStorage(tap);
    // No storage (allocation failed in init): pass the source audio
    // through untouched rather than touching shared state.
    if (storage == NULL || storage->equalizer == nil) return;
    [storage->equalizer processBufferList:bufferListInOut
                               frameCount:(NSInteger)sourceFrames
                                 tapState:&storage->dsp];
}
