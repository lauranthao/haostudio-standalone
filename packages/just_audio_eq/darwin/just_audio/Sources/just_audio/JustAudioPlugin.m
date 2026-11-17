#import "./include/just_audio/JustAudioPlugin.h"
#import "./include/just_audio/AudioPlayer.h"
#import "HaoEqualizer.h"
#import <AVFoundation/AVFoundation.h>
#include <TargetConditionals.h>

@implementation JustAudioPlugin {
    NSObject<FlutterPluginRegistrar>* _registrar;
    NSMutableDictionary<NSString *, AudioPlayer *> *_players;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
        methodChannelWithName:@"com.ryanheise.just_audio.methods"
              binaryMessenger:[registrar messenger]];
    JustAudioPlugin* instance = [[JustAudioPlugin alloc] initWithRegistrar:registrar];
    [registrar addMethodCallDelegate:instance channel:channel];
    // HAo equalizer channel (vendored fork — see HAO_PATCH.md): Dart
    // pushes {enabled, gains[10], preamp} here; the same instance
    // handles it (method names do not collide with init/dispose*).
    // The EQ engine lives in this plugin because only this plugin can
    // reach the AVPlayerItems (see HaoEqualizer.h).
    FlutterMethodChannel* eqChannel = [FlutterMethodChannel
        methodChannelWithName:@"com.haostudio.standalone/equalizer"
              binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:instance channel:eqChannel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _players = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    //NSLog(@"plugin method: %@", call.method);
    // HAo equalizer (vendored fork — see HAO_PATCH.md): Dart pushes
    // live EQ settings; the singleton retunes running taps immediately
    // and re-applies audioMix to live items on an enabled-flag change.
    if ([@"updateSettings" isEqualToString:call.method]) {
        NSDictionary *args = (NSDictionary *)call.arguments;
        BOOL enabled = [args[@"enabled"] boolValue];
        NSArray *gains = args[@"gains"];
        double preamp = [args[@"preamp"] doubleValue];
        [[HaoEqualizer shared] updateSettingsWithEnabled:enabled
                                                    gains:gains
                                                   preamp:preamp];
        result(nil);
        return;
    }
    if ([@"init" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = (NSString *)request[@"id"];
        NSDictionary *loadConfiguration = (NSDictionary *)request[@"audioLoadConfiguration"];
        BOOL useLazyPreparation = [((NSNumber *)request[@"useLazyPreparation"]) boolValue];
        if ([_players objectForKey:playerId] != nil) {
            FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Platform player already exists" details:nil];
            result(flutterError);
        } else {
            AudioPlayer* player = [[AudioPlayer alloc] initWithRegistrar:_registrar playerId:playerId loadConfiguration:loadConfiguration useLazyPreparation:useLazyPreparation];
            [_players setValue:player forKey:playerId];
            result(nil);
        }
    } else if ([@"disposePlayer" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = request[@"id"];
        [_players[playerId] dispose:NO];
        [_players setValue:nil forKey:playerId];
        result(@{});
    } else if ([@"disposeAllPlayers" isEqualToString:call.method]) {
        for (NSString *playerId in _players) {
            [_players[playerId] dispose:NO];
        }
        [_players removeAllObjects];
        result(@{});
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)dealloc {
    for (NSString *playerId in _players) {
        [_players[playerId] dispose:YES];
    }
    [_players removeAllObjects];
}

@end
