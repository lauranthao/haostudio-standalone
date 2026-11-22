// Music transport controls, iOS-native (build 29 adoption).
//
// iOS: the real SwiftUI buttons from
// ios/Runner/MusicTransportPlugin.swift, hosted in a `UiKitView` —
// prev / play-pause / next, three equal slots, bare white triangles
// (25pt semibold prev/next, 36pt bold play/pause — chen's
// screenshot). Other platforms, or when [nativeEnabled] is false
// (the default): the [fallback] widget verbatim — the player page's
// current Flutter transport row, so the page behaves exactly as
// before until the plugin is registered (AppDelegate + Runner
// target) and the page flips the flag.
//
// Single source of truth: the Flutter-side [playing] prop. The
// native view only mirrors it — Dart pushes `setState` when props
// change, the native side only reports user taps as `onTap`
// {id, action} on the events channel, and Dart echoes nothing back
// for its own taps (the parent rebuild carries the same value, so
// `didUpdateWidget` sees no diff). No second state is created
// anywhere. Music still plays through AVPlayer — this only swaps
// the three buttons, never the engine.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Platform-view type registered by MusicTransportPlugin.
const String nativeMusicTransportViewType =
    'com.haostudio.standalone/music_transport';

/// Command channel (Dart -> native): setState {playing}.
/// Must match ios/Runner/MusicTransportPlugin.swift.
const String nativeMusicTransportCommandChannel =
    'com.haostudio.standalone/music_transport';

/// Event channel (native -> Dart): onTap {id, action}. Must match
/// ios/Runner/MusicTransportPlugin.swift.
const String nativeMusicTransportEventChannel =
    'com.haostudio.standalone/music_transport/events';

/// Actions the native transport reports. The raw values must match
/// the Swift `MusicTransportAction` enum.
enum MusicTransportAction {
  prev,
  playPause,
  next;

  static MusicTransportAction? fromName(String? name) {
    for (final action in MusicTransportAction.values) {
      if (action.name == name) return action;
    }
    return null;
  }
}

/// The music transport cluster: prev / play-pause / next.
///
/// [onAction] receives the tapped action; the page maps it to the
/// existing callbacks (`prev`, play/pause toggle, `next`).
/// [fallback] is the page's current Flutter transport row, rendered
/// whenever the native view is not used.
class NativeMusicTransport extends StatefulWidget {
  const NativeMusicTransport({
    super.key,
    required this.playing,
    required this.onAction,
    required this.fallback,
    this.nativeEnabled = false,
  });

  /// Whether the play/pause button shows pause.
  final bool playing;

  final ValueChanged<MusicTransportAction> onAction;

  /// The Flutter transport row, rendered off-iOS or while the
  /// native view is disabled.
  final Widget fallback;

  /// False (default) = Flutter fallback on every platform.
  /// True + iOS = the SwiftUI view (needs the plugin registered).
  final bool nativeEnabled;

  @override
  State<NativeMusicTransport> createState() => _NativeMusicTransportState();
}

class _NativeMusicTransportState extends State<NativeMusicTransport> {
  static const MethodChannel _commandChannel =
      MethodChannel(nativeMusicTransportCommandChannel);
  static const MethodChannel _eventChannel =
      MethodChannel(nativeMusicTransportEventChannel);

  static int _nextId = 1;
  static final Map<int, _NativeMusicTransportState> _live = {};
  static bool _eventsInstalled = false;

  late final int _id;

  /// Last state the native view holds (or the fallback rendered).
  /// Initialised from the props; updated on native taps and on
  /// prop changes, so a push only happens on a real diff.
  late bool _nativePlaying;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;
  bool get _useNative => widget.nativeEnabled && _isIOS;

  @override
  void initState() {
    super.initState();
    _id = _nextId++;
    _nativePlaying = widget.playing;
    _live[_id] = this;
    _installEventHandler();
  }

  static void _installEventHandler() {
    if (_eventsInstalled) return;
    _eventsInstalled = true;
    _eventChannel.setMethodCallHandler((call) async {
      if (call.method != 'onTap') return null;
      final args = call.arguments;
      if (args is! Map) return null;
      final id = (args['id'] as num?)?.toInt();
      final action =
          MusicTransportAction.fromName(args['action'] as String?);
      final state = id == null ? null : _live[id];
      if (state != null && action != null && state.mounted) {
        state._onNativeTap(action);
      }
      return null;
    });
  }

  @override
  void didUpdateWidget(NativeMusicTransport oldWidget) {
    super.didUpdateWidget(oldWidget);
    // No "view created" guard: the native side silently ignores a
    // command for an id whose view does not exist yet, and
    // creationParams already carry the latest values — so a push
    // here can only help, never duplicate or crash.
    if (widget.playing != _nativePlaying) {
      _nativePlaying = widget.playing;
      _push('setState', {'playing': widget.playing});
    }
  }

  @override
  void dispose() {
    _live.remove(_id);
    super.dispose();
  }

  void _onNativeTap(MusicTransportAction action) {
    // No echo: the parent rebuilds with the new state, and
    // didUpdateWidget then sees widget.playing == _nativePlaying.
    if (action == MusicTransportAction.playPause) {
      _nativePlaying = !_nativePlaying;
    }
    widget.onAction(action);
  }

  void _push(String method, Map<String, Object?> args) {
    if (!_useNative) return;
    unawaited(
      _commandChannel
          .invokeMethod(method, {'id': _id, ...args})
          // Best-effort (same convention as SystemVolume): a missing
          // native side never throws into the build/gesture path.
          .catchError((_) => null),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_useNative) return widget.fallback;
    final params = <String, Object?>{
      'id': _id,
      'playing': widget.playing,
    };
    // Full-width row, 64pt tall (the play slot's height); the
    // SwiftUI HStack splits the width into three equal slots.
    return SizedBox(
      height: 64,
      child: UiKitView(
        viewType: nativeMusicTransportViewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }
}
