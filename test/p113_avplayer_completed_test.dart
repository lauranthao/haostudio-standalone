// P1-1: AVPlayer completedStream never fired.
//
// AvPlayerBackend exposed completedStream from a controller that
// nothing ever fed: no `_completedController.add(...)` anywhere in
// the file, so with AVPlayer as the active engine a VOD ending never
// reached PlaybackStatus.completed and auto-play-next never fired
// (MPV and IJK both feed theirs from a native completed signal).
//
// Fix: subscribe to BetterPlayer's own finished event — the SDK
// posts BetterPlayerEventType.finished when the underlying AVPlayer
// emits VideoEventType.completed (better_player_plus 1.4.1,
// core/better_player_controller.dart, `_handleVideoEvent`), the same
// class of signal MPV (`_player.stream.completed`) and IJK
// (`FijkState.completed`) already use. No position==duration polling.
//
// These tests drive the listener the backend registered on the REAL
// SDK controller (via the `debugController` test seam) with synthetic
// finished events, on a mocked `better_player_channel` so the native
// setup never runs. Brother case (MPV/IJK completed still normal):
// run test/kernel_recovery_test.dart + test/playback_session_* —
// MPV/IJK completed paths are native-event driven and untouched by
// this fix.

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/avplayer_backend.dart';

const _channel = MethodChannel('better_player_channel');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'create') return {'textureId': 1};
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<AvPlayerBackend> openedBackend() async {
    final backend = AvPlayerBackend();
    await backend.open(url: 'https://example.com/v.mp4', isLive: false);
    return backend;
  }

  test('finished event from the SDK controller completes exactly once',
      () async {
    final backend = await openedBackend();
    final controller = backend.debugController;
    expect(controller, isNotNull);
    // The backend registered exactly one listener on the real SDK
    // controller (nothing else subscribes to BetterPlayer events).
    expect(controller!.eventListeners.length, 1);
    final listener = controller.eventListeners.single!;

    final completed = <void>[];
    final sub = backend.completedStream.listen(completed.add);
    // BetterPlayer can post `finished` twice for one ending (natural
    // end + a seek past the duration); the stream must fire once.
    listener(BetterPlayerEvent(BetterPlayerEventType.finished));
    listener(BetterPlayerEvent(BetterPlayerEventType.finished));
    await Future<void>.delayed(Duration.zero);
    expect(completed.length, 1);

    await sub.cancel();
    await backend.dispose();
  });

  test('non-finished events never complete', () async {
    final backend = await openedBackend();
    final listener = backend.debugController!.eventListeners.single!;

    final completed = <void>[];
    final sub = backend.completedStream.listen(completed.add);
    for (final type in [
      BetterPlayerEventType.play,
      BetterPlayerEventType.pause,
      BetterPlayerEventType.bufferingStart,
      BetterPlayerEventType.progress,
      BetterPlayerEventType.initialized,
    ]) {
      listener(BetterPlayerEvent(type));
    }
    await Future<void>.delayed(Duration.zero);
    expect(completed, isEmpty);

    await sub.cancel();
    await backend.dispose();
  });

  test('a second open() re-arms the once-per-open guard', () async {
    final backend = await openedBackend();
    final completed = <void>[];
    final sub = backend.completedStream.listen(completed.add);

    backend.debugController!.eventListeners.single!(
      BetterPlayerEvent(BetterPlayerEventType.finished),
    );
    await Future<void>.delayed(Duration.zero);
    expect(completed.length, 1);

    // Re-open (new SDK controller): the next ending must fire again.
    await backend.open(url: 'https://example.com/v2.mp4', isLive: false);
    expect(backend.debugController!.eventListeners.length, 1);
    backend.debugController!.eventListeners.single!(
      BetterPlayerEvent(BetterPlayerEventType.finished),
    );
    await Future<void>.delayed(Duration.zero);
    expect(completed.length, 2);

    await sub.cancel();
    await backend.dispose();
  });
}
