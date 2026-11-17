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

// One biquad section. Beans BiquadCoefficients (b0 b1 b2 a1 a2).
typedef struct {
    float b0, b1, b2, a1, a2;
} HaoBiquad;

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
    // Live DSP state, read by the tap process callback under _lock.
    // Beans: processingEnabled / processingGains / processingPreampLinear /
    // processingFormatIsFloat32 / sampleRate / coefficients / filterStates.
    BOOL _processingEnabled;
    float _processingPreampLinear;
    BOOL _processingFormatIsFloat32;
    double _sampleRate;
    HaoBiquad _coefficients[10];
    // Beans filterStates: 80 = 8 channels x 10 bands, z1/z2 per section.
    float _filterZ1[8 * 10];
    float _filterZ2[8 * 10];
    // Weak registry of every AVPlayerItem created while this engine
    // lives (both crossfade players, gapless playerItem2 included).
    // Lets an enable/disable toggle re-apply audioMix to live items
    // without knowing which just_audio player owns them.
    NSHashTable<AVPlayerItem *> *_liveItems;
}

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
        _processingFormatIsFloat32 = NO;
        _sampleRate = 44100;
        for (int i = 0; i < 10; i++) {
            _gains[i] = 0;
            _coefficients[i] = (HaoBiquad){1, 0, 0, 0, 0};
        }
        memset(_filterZ1, 0, sizeof(_filterZ1));
        memset(_filterZ2, 0, sizeof(_filterZ2));
        _liveItems = [NSHashTable weakObjectsHashTable];
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
        [self rebuildCoefficientsLocked];
    }
    _preampDb = HaoNormalizedGain(preamp);
    _processingPreampLinear = HaoLinearGain(_preampDb);
    [_lock unlock];
    // Gain/preamp changes are picked up live by running taps (the
    // process callback reads _coefficients under the lock). Only an
    // enabled-flag change needs audioMix set/cleared on live items.
    if (enabledChanged) {
        [self reapplyToLiveItems];
    }
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

- (void)rebuildCoefficientsLocked {
    for (int i = 0; i < 10; i++) {
        _coefficients[i] = HaoBiquadPeaking(HaoBandFrequencies[i], _gains[i],
                                            _sampleRate);
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
    AVMutableAudioMixInputParameters *params =
        [[AVMutableAudioMixInputParameters alloc] initWithTrack:track];
    params.audioTapProcessor = tap;
    // audioTapProcessor retains the tap; release our create reference.
    CFRelease(tap);
    AVMutableAudioMix *mix = [[AVMutableAudioMix alloc] init];
    mix.inputParameters = @[params];
    return mix;
}

// Beans prepare(with:): capture sample rate + Float32-ness, reset all
// filter state, rebuild coefficients for the real sample rate.
- (void)prepareWithFormat:(const AudioStreamBasicDescription *)format {
    [_lock lock];
    _sampleRate = fmax(format->mSampleRate, 8000);
    _processingFormatIsFloat32 =
        format->mFormatID == kAudioFormatLinearPCM &&
        format->mBitsPerChannel == 32 &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    memset(_filterZ1, 0, sizeof(_filterZ1));
    memset(_filterZ2, 0, sizeof(_filterZ2));
    [self rebuildCoefficientsLocked];
    [_lock unlock];
}

// Beans process(bufferList:frameCount:), transliterated: preamp, then
// the 10 biquads in series per sample per channel, clamp +-4,
// non-finite -> 0. Runs on the realtime audio thread; shared state is
// read under _lock, exactly like Beans' configurationLock.
- (void)processBufferList:(AudioBufferList *)bufferList
               frameCount:(NSInteger)frameCount {
    if (frameCount <= 0) return;
    [_lock lock];
    if (!_processingEnabled || !_processingFormatIsFloat32) {
        [_lock unlock];
        return;
    }
    float preampLinear = _processingPreampLinear;
    HaoBiquad coefficients[10];
    memcpy(coefficients, _coefficients, sizeof(coefficients));
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
                float sample = samples[sampleIndex] * preampLinear;
                for (int bandIndex = 0; bandIndex < 10; bandIndex++) {
                    NSInteger stateIndex = stateOffset + bandIndex;
                    HaoBiquad coefficient = coefficients[bandIndex];
                    float z1 = _filterZ1[stateIndex];
                    float z2 = _filterZ2[stateIndex];
                    float filtered = coefficient.b0 * sample + z1;
                    z1 = coefficient.b1 * sample -
                        coefficient.a1 * filtered + z2;
                    z2 = coefficient.b2 * sample -
                        coefficient.a2 * filtered;
                    _filterZ1[stateIndex] = z1;
                    _filterZ2[stateIndex] = z2;
                    sample = filtered;
                }
                samples[sampleIndex] =
                    isfinite(sample) ? fminf(fmaxf(sample, -4), 4) : 0;
            }
        }
        firstChannelIndex += channelCount;
    }
    [_lock unlock];
}

@end

// MARK: - Tap callbacks (C functions, Beans equalizerTap*)

static void HaoEqualizerTapInit(MTAudioProcessingTapRef tap,
                                void *clientInfo, void **tapStorageOut) {
    (void)tap;
    *tapStorageOut = clientInfo;
}

static void HaoEqualizerTapFinalize(MTAudioProcessingTapRef tap) {
    (void)tap;
}

static void HaoEqualizerTapPrepare(MTAudioProcessingTapRef tap,
                                   CMItemCount maxFrames,
                                   const AudioStreamBasicDescription *processingFormat) {
    (void)maxFrames;
    void *storage = MTAudioProcessingTapGetStorage(tap);
    HaoEqualizer *equalizer = (__bridge HaoEqualizer *)storage;
    [equalizer prepareWithFormat:processingFormat];
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
    void *storage = MTAudioProcessingTapGetStorage(tap);
    HaoEqualizer *equalizer = (__bridge HaoEqualizer *)storage;
    [equalizer processBufferList:bufferListInOut
                      frameCount:(NSInteger)sourceFrames];
}
