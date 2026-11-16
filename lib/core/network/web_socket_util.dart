// Shared WebSocket helper for the danmaku transports.
//
// Compact port of Pure Live 3.x `lib/core/network/web_socket_util.dart`
// (WebScoketUtils): endpoint failover, heartbeat timer, bounded reconnects
// (max 8), inactivity watchdog, generation guards so a stale socket can
// never deliver into a new room.
//
// Uses `IOWebSocketChannel` (dart:io WebSocket) so handshake headers —
// notably Douyin's `Cookie: ttwid=…` — CAN be sent. A browser/WKWebView
// JS WebSocket cannot send Cookie headers; that is why Douyin danmaku
// was impossible on web and is portable here.
//
// Danmaku is best-effort: a transport failure must never crash the room.
// Callers treat [onClose] as "danmaku unavailable, video continues".

import 'dart:async';
import 'dart:io' as io;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef WebSocketConnector = WebSocketChannel Function(
  String endpoint, {
  Duration? connectTimeout,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  io.HttpClient? customClient,
});

WebSocketChannel _connectIoWebSocket(
  String endpoint, {
  Duration? connectTimeout,
  Iterable<String>? protocols,
  Map<String, dynamic>? headers,
  io.HttpClient? customClient,
}) {
  return IOWebSocketChannel.connect(
    endpoint,
    connectTimeout: connectTimeout,
    protocols: protocols,
    headers: headers,
    customClient: customClient,
  );
}

enum SocketStatus { connected, failed, closed }

/// One-shot-retry WebSocket with endpoint rotation.
///
/// The original Pure Live helper kept a periodic reconnect timer alive
/// after a successful connection, which could spawn parallel sockets.
/// This port uses one-shot retries and rotates through [serverUrls].
class WebSocketUtils {
  WebSocketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onFailure,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.protocols,
    this.inactivityTimeout,
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.shutdownTimeout = const Duration(seconds: 2),
    this.connector = _connectIoWebSocket,
    List<String>? serverUrls,
  }) : serverUrls = _uniqueEndpoints(url, serverUrls);

  /// Primary endpoint.
  final String url;

  /// Ordered endpoints used for connection and failover.
  final List<String> serverUrls;

  /// Heartbeat interval in milliseconds (0 = no heartbeat).
  final int heartBeatTime;

  /// Raw frames (`String` or `List<int>`, depending on the server).
  final void Function(dynamic data)? onMessage;

  /// Terminal failure: reconnect budget exhausted or manual close reason.
  final void Function(String message)? onClose;

  /// Non-terminal failure (a reconnect will be attempted).
  final void Function(String message)? onFailure;

  /// Called on the FIRST reconnect attempt after a drop.
  final void Function()? onReconnect;

  /// Called when the socket is open and ready for frames.
  final void Function()? onReady;

  /// Called every [heartBeatTime] while connected.
  final void Function()? onHeartBeat;

  final Map<String, dynamic>? headers;
  final Iterable<String>? protocols;

  /// No inbound frame for this long => reconnect. Defaults to
  /// max(3 × heartbeat, 90 s).
  final Duration? inactivityTimeout;

  final Duration reconnectBaseDelay;
  final Duration shutdownTimeout;
  final WebSocketConnector connector;

  SocketStatus status = SocketStatus.closed;

  WebSocketChannel? _channel;
  Timer? _heartBeatTimer;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _subscription;

  int reconnectTime = 0;
  int maxReconnectTime = 8;
  int _endpointIndex = 0;
  int _generation = 0;
  bool _manualClose = false;
  bool _connecting = false;
  Completer<void>? _connectAbort;
  Completer<void>? _connectDone;
  DateTime? _lastMessageAt;

  static List<String> _uniqueEndpoints(String primary, List<String>? candidates) {
    final endpoints = <String>[];
    for (final endpoint in <String>[primary, ...?candidates]) {
      final value = endpoint.trim();
      if (value.isNotEmpty && !endpoints.contains(value)) endpoints.add(value);
    }
    return endpoints;
  }

  Future<void> connect({bool retry = false}) async {
    if (_connecting) {
      await _connectDone?.future;
      return;
    }
    if (serverUrls.isEmpty) return;
    _manualClose = false;
    _connecting = true;
    final generation = ++_generation;
    final abort = Completer<void>();
    final done = Completer<void>();
    _connectAbort = abort;
    _connectDone = done;
    try {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      await _disposeSocket();
      if (abort.isCompleted || _manualClose || generation != _generation) return;
      if (retry && serverUrls.length > 1) {
        _endpointIndex = (_endpointIndex + 1) % serverUrls.length;
      }
      final endpoint = serverUrls[_endpointIndex % serverUrls.length];
      final channel = connector(
        endpoint,
        connectTimeout: const Duration(seconds: 10),
        protocols: protocols,
        headers: headers,
      );
      _channel = channel;
      try {
        await Future.any<void>([channel.ready, abort.future]);
      } catch (_) {
        // `channel.ready` failed: fall through to the reconnect path.
        if (!_manualClose && generation == _generation) {
          _scheduleReconnect('WebSocket handshake failed: $endpoint');
        }
        return;
      }
      if (abort.isCompleted || _manualClose || generation != _generation) {
        if (identical(_channel, channel)) {
          _channel = null;
          unawaited(_closeSocket(channel));
        }
        return;
      }
      _ready(channel, generation);
    } catch (error) {
      if (!_manualClose && generation == _generation) {
        _scheduleReconnect(error.toString());
      }
    } finally {
      if (identical(_connectAbort, abort)) _connectAbort = null;
      if (identical(_connectDone, done)) {
        _connectDone = null;
        _connecting = false;
      }
      if (!done.isCompleted) done.complete();
    }
  }

  void _ready(WebSocketChannel channel, int generation) {
    status = SocketStatus.connected;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _lastMessageAt = DateTime.now();
    _subscription = channel.stream.listen(
      (data) {
        if (!_manualClose && generation == _generation) {
          reconnectTime = 0;
          _lastMessageAt = DateTime.now();
          onMessage?.call(data);
        }
      },
      onError: (Object error, StackTrace _) {
        if (!_manualClose && generation == _generation) {
          _scheduleReconnect(error.toString());
        }
      },
      onDone: () {
        if (!_manualClose && generation == _generation) {
          final code = channel.closeCode;
          final reason = channel.closeReason?.trim();
          _scheduleReconnect(
            'WebSocket closed'
            '${code == null ? '' : ' (code=$code)'}'
            '${reason == null || reason.isEmpty ? '' : ': $reason'}',
          );
        }
      },
      cancelOnError: true,
    );
    onReady?.call();
    _initHeartBeat();
  }

  void _initHeartBeat() {
    _heartBeatTimer?.cancel();
    if (heartBeatTime <= 0) return;
    _heartBeatTimer = Timer.periodic(Duration(milliseconds: heartBeatTime), (_) {
      if (status != SocketStatus.connected) return;
      final lastMessageAt = _lastMessageAt;
      if (lastMessageAt != null &&
          DateTime.now().difference(lastMessageAt) >= _resolvedInactivityTimeout) {
        _scheduleReconnect('WebSocket heartbeat timed out');
        return;
      }
      onHeartBeat?.call();
    });
  }

  Duration get _resolvedInactivityTimeout {
    final configured = inactivityTimeout;
    if (configured != null) return configured;
    final heartbeatWindow = Duration(milliseconds: heartBeatTime * 3);
    const minimumWindow = Duration(seconds: 90);
    return heartbeatWindow > minimumWindow ? heartbeatWindow : minimumWindow;
  }

  void _scheduleReconnect(String message) {
    if (_manualClose || _reconnectTimer?.isActive == true) return;
    onFailure?.call(message);
    status = SocketStatus.failed;
    _heartBeatTimer?.cancel();
    _heartBeatTimer = null;
    if (reconnectTime == 0) onReconnect?.call();
    if (reconnectTime >= maxReconnectTime) {
      onClose?.call('重连超过最大次数，与服务器断开连接：$message');
      unawaited(close());
      return;
    }
    reconnectTime++;
    _endpointIndex = (_endpointIndex + 1) % serverUrls.length;
    final completedRounds = reconnectTime ~/ serverUrls.length;
    final delayMultiplier = completedRounds.clamp(0, 5) + 1;
    final delay = Duration(
      microseconds: reconnectBaseDelay.inMicroseconds * delayMultiplier,
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      connect();
    });
  }

  void sendMessage(dynamic message) {
    if (status != SocketStatus.connected) return;
    try {
      _channel?.sink.add(message);
    } catch (error) {
      _scheduleReconnect(error.toString());
    }
  }

  Future<void> _disposeSocket({bool awaitSocketClose = true}) async {
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel().timeout(shutdownTimeout);
    } catch (_) {}
    _heartBeatTimer?.cancel();
    _heartBeatTimer = null;
    final socket = _channel;
    _channel = null;
    _lastMessageAt = null;
    if (socket == null) return;
    final closeFuture = _closeSocket(socket);
    if (awaitSocketClose) {
      try {
        await closeFuture.timeout(shutdownTimeout);
      } on TimeoutException {
        // The close future stays observed by `_closeSocket`.
      }
    } else {
      unawaited(closeFuture);
    }
  }

  Future<void> _closeSocket(WebSocketChannel socket) async {
    try {
      await socket.sink.close();
    } catch (_) {}
  }

  Future<void> close() async {
    _manualClose = true;
    _generation++;
    status = SocketStatus.closed;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final pendingConnect = _connectDone?.future;
    final abort = _connectAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    await _disposeSocket(awaitSocketClose: pendingConnect == null);
    await pendingConnect;
  }

  void reconnect() {
    if (!_manualClose) _scheduleReconnect('Reconnect requested');
  }
}
