// Now Playing channel tests (Fix 14) — Dart side of the iOS Now Playing
// shell (ios/Runner/NowPlayingPlugin.swift).
//
// - updateTrack / clear push the right method + arguments to Swift.
// - Incoming remoteCommand calls reach the handler exactly once per
//   press: a duplicate next/previous within 300 ms is dropped, so one
//   press can never advance two tracks.
// - Play / pause / toggle / seek pass through; unknown or malformed
//   commands are ignored, never thrown.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/native/now_playing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(nowPlayingChannelName);
  const codec = StandardMethodCodec();

  late List<MethodCall> outgoing;
  late NowPlayingService service;

  setUp(() {
    outgoing = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      outgoing.add(call);
      return null;
    });
    service = NowPlayingService();
  });

  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> sendRemote(String command, {double? position}) async {
    final args = <String, Object>{'command': command};
    if (position != null) args['position'] = position;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      nowPlayingChannelName,
      codec.encodeMethodCall(MethodCall('remoteCommand', args)),
      (_) {},
    );
  }

  group('outgoing: updateTrack / clear', () {
    test('updateTrack sends title/artist/album/cover + seconds as double', () async {
      await service.updateTrack(
        title: 'Song Title',
        artist: 'Artist',
        album: 'Album',
        coverUrl: 'https://example.com/cover.jpg',
        duration: const Duration(minutes: 3, seconds: 20),
        position: const Duration(seconds: 12, milliseconds: 500),
        playing: true,
      );
      expect(outgoing, hasLength(1));
      final call = outgoing.single;
      expect(call.method, 'updateNowPlaying');
      final args = call.arguments as Map;
      expect(args['title'], 'Song Title');
      expect(args['artist'], 'Artist');
      expect(args['album'], 'Album');
      expect(args['coverUrl'], 'https://example.com/cover.jpg');
      expect(args['duration'], 200.0);
      expect(args['position'], 12.5);
      expect(args['playing'], isTrue);
    });

    test('updateTrack defaults empty strings and zero durations', () async {
      await service.updateTrack(title: 'Only Title', playing: false);
      final args = (outgoing.single.arguments as Map);
      expect(args['artist'], '');
      expect(args['album'], '');
      expect(args['coverUrl'], '');
      expect(args['duration'], 0.0);
      expect(args['position'], 0.0);
      expect(args['playing'], isFalse);
    });

    test('clear sends clearNowPlaying', () async {
      await service.clear();
      expect(outgoing, hasLength(1));
      expect(outgoing.single.method, 'clearNowPlaying');
    });
  });

  group('incoming: remote commands', () {
    test('play / pause / toggle each reach the handler once', () async {
      final received = <NowPlayingRemoteCommand>[];
      service.onRemoteCommand = (cmd, {position}) async {
        received.add(cmd);
      };
      await sendRemote('play');
      await sendRemote('pause');
      await sendRemote('toggle');
      expect(received, [
        NowPlayingRemoteCommand.play,
        NowPlayingRemoteCommand.pause,
        NowPlayingRemoteCommand.toggle,
      ]);
    });

    test('seek passes the position through', () async {
      NowPlayingRemoteCommand? gotCommand;
      double? gotPosition;
      service.onRemoteCommand = (cmd, {position}) async {
        gotCommand = cmd;
        gotPosition = position;
      };
      await sendRemote('seek', position: 42.5);
      expect(gotCommand, NowPlayingRemoteCommand.seek);
      expect(gotPosition, 42.5);
    });

    test('duplicate next within 300 ms is dropped (one press = one track)', () async {
      var count = 0;
      service.onRemoteCommand = (cmd, {position}) async {
        if (cmd == NowPlayingRemoteCommand.next) count++;
      };
      await sendRemote('next');
      await sendRemote('next');
      expect(count, 1);
    });

    test('duplicate previous within 300 ms is dropped', () async {
      var count = 0;
      service.onRemoteCommand = (cmd, {position}) async {
        if (cmd == NowPlayingRemoteCommand.previous) count++;
      };
      await sendRemote('previous');
      await sendRemote('previous');
      expect(count, 1);
    });

    test('next after the dedupe window fires again', () async {
      var count = 0;
      service.onRemoteCommand = (cmd, {position}) async {
        if (cmd == NowPlayingRemoteCommand.next) count++;
      };
      await sendRemote('next');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await sendRemote('next');
      expect(count, 2);
    });

    test('next then previous are different commands, both fire', () async {
      final received = <NowPlayingRemoteCommand>[];
      service.onRemoteCommand = (cmd, {position}) async {
        received.add(cmd);
      };
      await sendRemote('next');
      await sendRemote('previous');
      expect(received, [
        NowPlayingRemoteCommand.next,
        NowPlayingRemoteCommand.previous,
      ]);
    });

    test('unknown command, wrong method and malformed args are ignored', () async {
      var called = false;
      service.onRemoteCommand = (cmd, {position}) async {
        called = true;
      };
      await sendRemote('bogus');
      // Wrong method name.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        nowPlayingChannelName,
        codec.encodeMethodCall(const MethodCall('somethingElse', null)),
        (_) {},
      );
      // Malformed arguments (not a map).
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        nowPlayingChannelName,
        codec.encodeMethodCall(const MethodCall('remoteCommand', 'not-a-map')),
        (_) {},
      );
      // Map without a command.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        nowPlayingChannelName,
        codec.encodeMethodCall(
            const MethodCall('remoteCommand', <String, Object>{})),
        (_) {},
      );
      expect(called, isFalse);
    });

    test('no handler set: incoming command does not throw', () async {
      service.onRemoteCommand = null;
      await sendRemote('next');
      await sendRemote('seek', position: 10);
    });
  });
}
