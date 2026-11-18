#import "./include/just_audio/UriAudioSource.h"
#import "./include/just_audio/IndexedAudioSource.h"
#import "./include/just_audio/IndexedPlayerItem.h"
#import "./include/just_audio/LoadControl.h"
#import "HaoEqualizer.h"
#import <AVFoundation/AVFoundation.h>

// HAo fork default (see HAO_PATCH.md §7): seconds of audio AVPlayer
// should keep buffered ahead of the playhead for REMOTE http(s) items
// when the app did not configure DarwinLoadControl
// .preferredForwardBufferDuration. Upstream just_audio leaves the
// property at its default (0 = system chooses, small on progressive
// download), and the app constructs AudioPlayer() with no
// audioLoadConfiguration, so network songs stalled mid-track and at
// crossfade start. 10 s: ~400 KB at 320 kbps, ~1.25 MB at lossless
// ~1 Mbps per item — negligible — while covering a multi-second CDN
// hiccup / network handover. Larger (30-60 s) would delay first audio
// more on slow networks and waste bandwidth on skips; smaller (3-5 s)
// would not cover the stalls chen reported. An explicit
// DarwinLoadControl value always wins over this default, and file://
// items never get it (local disk needs no forward buffer).
static const double HaoDefaultForwardBufferDurationSeconds = 10.0;

@implementation UriAudioSource {
    NSString *_uri;
    IndexedPlayerItem *_playerItem;
    IndexedPlayerItem *_playerItem2;
    /* CMTime _duration; */
    LoadControl *_loadControl;
    NSMutableDictionary *_headers;
    NSDictionary *_options;
}

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options {
    self = [super initWithId:sid];
    NSAssert(self, @"super init cannot be nil");
    _uri = uri;
    _loadControl = loadControl;
    _headers = headers != (id)[NSNull null] ? [headers mutableCopy] : nil;
    _options = options;
    _playerItem = [self createPlayerItem:uri];
    _playerItem2 = nil;
    return self;
}

- (NSString *)uri {
    return _uri;
}

- (IndexedPlayerItem *)createPlayerItem:(NSString *)uri {
    IndexedPlayerItem *item;
    NSMutableDictionary *assetOptions = [[NSMutableDictionary alloc] init];
    BOOL isRemote = ![uri hasPrefix:@"file://"];

    if (_options != (id)[NSNull null]) {
        NSDictionary *darwinOptions = _options[@"darwinAssetOptions"];
        if (darwinOptions != (id)[NSNull null]) {
            assetOptions[AVURLAssetPreferPreciseDurationAndTimingKey] = darwinOptions[@"preferPreciseDurationAndTiming"];
        }
    }

    if (!isRemote) {
        NSURL *fileURL = [NSURL fileURLWithPath:[[uri stringByRemovingPercentEncoding] substringFromIndex:7]];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:assetOptions];
        item = [[IndexedPlayerItem alloc] initWithAsset:asset];
    } else {
        if (_headers) {
            // Use user-agent key if it is the only header and the API is supported.
            if ([_headers count] == 1) {
                if (@available(macOS 13.0, iOS 16.0, *)) {
                    NSString *userAgent = _headers[@"User-Agent"];
                    if (userAgent) {
                        [_headers removeObjectForKey:@"User-Agent"];
                    } else {
                        userAgent = _headers[@"user-agent"];
                        if (userAgent) {
                            [_headers removeObjectForKey:@"user-agent"];
                        }
                    }
                    if (userAgent) {
                        assetOptions[AVURLAssetHTTPUserAgentKey] = userAgent;
                    }
                }
            }
            if ([_headers count] > 0) {
                assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = _headers;
            }
        }
        
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:uri] options:assetOptions];
        item = [[IndexedPlayerItem alloc] initWithAsset:asset];
    }
    if (@available(macOS 10.13, iOS 11.0, *)) {
        // This does the best at reducing distortion on voice with speeds below 1.0
        item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
    }
    if (@available(macOS 10.12, iOS 10.0, *)) {
        NSNumber *configured = _loadControl.preferredForwardBufferDuration;
        if (configured != nil && configured != (id)[NSNull null]) {
            // Upstream 0.10.6 path, unchanged: Dart Duration arrives as
            // microseconds (DarwinLoadControlMessage encodes
            // inMicroseconds), so /1000 (ms, integer) then /1000.0 (s).
            // An explicit value always wins, including an explicit 0.
            item.preferredForwardBufferDuration = (double)([configured longLongValue]/1000) / 1000.0;
        } else if (isRemote) {
            // HAo fork default (see top of file): no configured value
            // (the app passes no audioLoadConfiguration) -> 10 s.
            // file:// items keep the system default (0).
            item.preferredForwardBufferDuration = HaoDefaultForwardBufferDurationSeconds;
        }
    }
    if (@available(iOS 9.0, macOS 10.11, *)) {
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
    }
    if (@available(iOS 8.0, macOS 10.10, *)) {
        if (_loadControl.preferredPeakBitRate != (id)[NSNull null]) {
            item.preferredPeakBitRate = [_loadControl.preferredPeakBitRate doubleValue];
        }
    }

    // HAo equalizer hook (vendored fork — see HAO_PATCH.md): this is the
    // ONLY place just_audio creates an AVPlayerItem, so it is where the
    // MTAudioProcessingTap audioMix is attached. It covers every item:
    // both A/B crossfade players (each just_audio AudioPlayer builds
    // its own UriAudioSource), the gapless playerItem2
    // (preparePlayerItem2 calls createPlayerItem again), and file:// +
    // http(s) URLs alike. When EQ is off, applyToItem clears audioMix
    // and only registers the item for a later enable toggle.
    [[HaoEqualizer shared] applyToItem:item];

    return item;
}

// Not used. XXX: Remove?
- (void)applyPreferredForwardBufferDuration {
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if (_loadControl.preferredForwardBufferDuration != (id)[NSNull null]) {
            double value = (double)([_loadControl.preferredForwardBufferDuration longLongValue]/1000) / 1000.0;
            _playerItem.preferredForwardBufferDuration = value;
            if (_playerItem2) {
                _playerItem2.preferredForwardBufferDuration = value;
            }
        }
    }
}

- (void)applyCanUseNetworkResourcesForLiveStreamingWhilePaused {
    if (@available(iOS 9.0, macOS 10.11, *)) {
        _playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
        if (_playerItem2) {
            _playerItem2.canUseNetworkResourcesForLiveStreamingWhilePaused = _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused;
        }
    }
}

- (void)applyPreferredPeakBitRate {
    if (@available(iOS 8.0, macOS 10.10, *)) {
        if (_loadControl.preferredPeakBitRate != (id)[NSNull null]) {
            double value = [_loadControl.preferredPeakBitRate doubleValue];
            _playerItem.preferredPeakBitRate = value;
            if (_playerItem2) {
                _playerItem2.preferredPeakBitRate = value;
            }
        }
    }
}

- (IndexedPlayerItem *)playerItem {
    return _playerItem;
}

- (IndexedPlayerItem *)playerItem2 {
    return _playerItem2;
}

- (NSArray<NSNumber *> *)getShuffleIndices {
    return @[@(0)];
}

- (void)play:(AVQueuePlayer *)player {
}

- (void)pause:(AVQueuePlayer *)player {
}

- (void)stop:(AVQueuePlayer *)player {
}

- (void)seek:(CMTime)position completionHandler:(void (^)(BOOL))completionHandler {
    if (!completionHandler || (_playerItem.status == AVPlayerItemStatusReadyToPlay)) {
        NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
        if (seekableRange) {
            CMTimeRange range = [seekableRange CMTimeRangeValue];
            position = CMTimeAdd(position, range.start);
        }
        [_playerItem seekToTime:position toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completionHandler];
    } else {
        [super seek:position completionHandler:completionHandler];
    }
}

- (void)flip {
    IndexedPlayerItem *temp = _playerItem;
    _playerItem = _playerItem2;
    _playerItem2 = temp;
}

- (void)preparePlayerItem2 {
    if (!_playerItem2) {
        _playerItem2 = [self createPlayerItem:_uri];
        _playerItem2.audioSource = _playerItem.audioSource;
    }
}

- (CMTime)duration {
    NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
    if (seekableRange) {
        CMTimeRange seekableDuration = [seekableRange CMTimeRangeValue];
        return seekableDuration.duration;
    }
    else {
        return _playerItem.duration;
    }
    return kCMTimeInvalid;
}

- (void)setDuration:(CMTime)duration {
}

- (CMTime)position {
    NSValue *seekableRange = _playerItem.seekableTimeRanges.lastObject;
    if (seekableRange) {
        CMTimeRange range = [seekableRange CMTimeRangeValue];
        return CMTimeSubtract(_playerItem.currentTime, range.start);
    } else {
        return _playerItem.currentTime;
    }
    
}

- (CMTime)bufferedPosition {
    NSValue *last = _playerItem.loadedTimeRanges.lastObject;
    if (last) {
        CMTimeRange timeRange = [last CMTimeRangeValue];
        return CMTimeAdd(timeRange.start, timeRange.duration);
    } else {
        return _playerItem.currentTime;
    }
    return kCMTimeInvalid;
}

@end
