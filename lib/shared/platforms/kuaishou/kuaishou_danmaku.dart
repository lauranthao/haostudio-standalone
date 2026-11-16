// Kuaishou danmaku — HTTP polling, not WebSocket.
//
// Port of Pure Live 3.x `lib/shared/platforms/kuaishou/kuaishou_danmaku.dart`
// (307 lines): polls the mobile incremental feed
//   GET https://livev.m.chenzhongtech.com/wap/live/feed
//   GET https://m.gifshow.com/wap/live/feed
// with `liveStreamId` (+ `cursor`), timer-driven, one poll at a time:
// the next poll is scheduled only after the previous request finishes,
// so there are no overlapping timers, duplicate cursors or background
// CPU growth.
//
// Args for [start] (from the room detail's `danmakuData`, with `roomId`
// fallback — the adapter is still a stub, so `liveStreamId` is resolved
// here when it is not supplied):
//   - `liveStreamId`: the live stream id (preferred).
//   - `roomId`: author/user id; when `liveStreamId` is absent the room
//     page `https://live.kuaishou.com/u/<roomId>` is scraped once for
//     `window.__INITIAL_STATE__` -> `room.liveStream.id`.
//   - `cookie`: optional session cookie header.
//
// Best-effort: poll failures back off exponentially (max 8 attempts)
// and then report [LiveDanmaku.onClose]; the video keeps playing.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../live_site.dart';

/// One parsed feed batch: cursor for the next poll, server-suggested
/// delay, and the chat messages in it.
class KuaishouFeedBatch {
  const KuaishouFeedBatch({
    required this.cursor,
    required this.pullDelay,
    required this.messages,
  });

  final String cursor;
  final Duration pullDelay;
  final List<LiveMessage> messages;
}

/// Injectable feed fetcher (defaults to the real HTTP feed; tests pass a
/// canned fetcher). Returns the decoded JSON payload.
typedef KuaishouFeedFetcher = Future<dynamic> Function(
  String liveStreamId,
  String cursor,
  String cookie,
  CancelToken cancelToken,
);

class KuaishouDanmaku extends LiveDanmaku {
  KuaishouDanmaku({
    KuaishouFeedFetcher? fetcher,
    this.minimumPollDelay = const Duration(seconds: 1),
  }) : _fetcher = fetcher ?? _fetchFeed;

  static const List<String> _feedUrls = <String>[
    'https://livev.m.chenzhongtech.com/wap/live/feed',
    'https://m.gifshow.com/wap/live/feed',
  ];
  static const int _maxReconnectAttempts = 8;

  final KuaishouFeedFetcher _fetcher;

  /// Floor for the poll interval (server may ask for longer).
  final Duration minimumPollDelay;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  Timer? _pollTimer;
  CancelToken? _cancelToken;
  String? _liveStreamId;
  String _cookie = '';
  String _cursor = '';
  int _generation = 0;
  int _reconnectAttempts = 0;

  @override
  Future<void> start(Map<String, dynamic> args) async {
    final generation = ++_generation;
    _pollTimer?.cancel();
    _pollTimer = null;
    _cancelToken?.cancel('Kuaishou room changed');
    _cancelToken = null;
    _cursor = '';
    _reconnectAttempts = 0;
    _connected = false;
    _cookie = args['cookie']?.toString() ?? '';

    var liveStreamId = args['liveStreamId']?.toString().trim() ?? '';
    if (liveStreamId.isEmpty) {
      // Fallback: resolve the liveStreamId from the room page.
      final roomId = args['roomId']?.toString().trim() ?? '';
      if (roomId.isEmpty) {
        onClose?.call();
        return;
      }
      liveStreamId = await _resolveLiveStreamId(roomId);
      if (generation != _generation) return;
      if (liveStreamId.isEmpty) {
        onClose?.call();
        return;
      }
    }
    _liveStreamId = liveStreamId;

    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 1 ? 600 : 1400),
        );
      }
      if (generation != _generation) return;
      try {
        await _pollOnce(generation, propagateFailure: true);
        if (generation != _generation) return;
        return;
      } catch (_) {
        // Retry the first poll; after 3 failures report via onClose.
      }
    }
    // First poll failed 3×: best-effort — report via onClose and give
    // up quietly. Never throw out of start(): danmaku must not crash
    // the room (Pure Live rethrows here; we deliberately do not).
    if (generation == _generation) {
      onClose?.call();
    }
  }

  Future<void> _pollOnce(
    int generation, {
    bool scheduleNext = true,
    bool propagateFailure = false,
  }) async {
    final liveStreamId = _liveStreamId;
    if (liveStreamId == null || generation != _generation) return;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    try {
      final raw = await _fetcher(
        liveStreamId,
        _cursor,
        _cookie,
        cancelToken,
      );
      if (generation != _generation || cancelToken.isCancelled) return;
      final batch = parseFeedPayload(raw);
      if (batch.cursor.isNotEmpty) _cursor = batch.cursor;
      _reconnectAttempts = 0;
      final wasConnected = _connected;
      _connected = true;
      if (!wasConnected) onReady?.call();
      for (final message in batch.messages) {
        if (generation != _generation) return;
        onMessage?.call(message);
      }
      if (scheduleNext) _schedulePoll(generation, batch.pullDelay);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || generation != _generation) return;
      if (propagateFailure) rethrow;
      _handlePollFailure(generation);
    } catch (_) {
      if (generation != _generation || cancelToken.isCancelled) return;
      if (propagateFailure) rethrow;
      _handlePollFailure(generation);
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  void _handlePollFailure(int generation) {
    _connected = false;
    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      onClose?.call();
      return;
    }
    if (_reconnectAttempts == 1) {
      onReconnect?.call();
    }
    final seconds = 1 << (_reconnectAttempts - 1).clamp(0, 3);
    _schedulePoll(generation, Duration(seconds: seconds));
  }

  void _schedulePoll(int generation, Duration requestedDelay) {
    if (generation != _generation) return;
    _pollTimer?.cancel();
    final delay = requestedDelay < minimumPollDelay
        ? minimumPollDelay
        : requestedDelay;
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      if (generation == _generation) unawaited(_pollOnce(generation));
    });
  }

  @override
  Future<void> heartbeat() async {
    // The incremental HTTP feed is itself the liveness probe.
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _cancelToken?.cancel('Kuaishou danmaku stopped');
    _cancelToken = null;
    _liveStreamId = null;
    _cursor = '';
    _reconnectAttempts = 0;
    _connected = false;
    onMessage = null;
    onReconnect = null;
    onClose = null;
    onReady = null;
  }

  /// Resolve `liveStreamId` from the room HTML page
  /// (`window.__INITIAL_STATE__` -> `room.liveStream.id`).
  /// Best-effort: returns '' on any failure.
  static Future<String> _resolveLiveStreamId(String roomId) async {
    try {
      final dio = sharedDio();
      final response = await dio.get<String>(
        'https://live.kuaishou.com/u/$roomId',
        options: Options(
          headers: <String, String>{
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
          responseType: ResponseType.plain,
        ),
      );
      final html = response.data ?? '';
      final match = RegExp(
        r'window\.__INITIAL_STATE__\s*=\s*(.*?);\s*</script>',
        dotAll: true,
      ).firstMatch(html);
      if (match == null) return '';
      final state = jsonDecode(match.group(1)!);
      if (state is! Map) return '';
      final room = state['room'];
      if (room is! Map) return '';
      final liveStream = room['liveStream'];
      if (liveStream is! Map) return '';
      return liveStream['id']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<dynamic> _fetchFeed(
    String liveStreamId,
    String cursor,
    String cookie,
    CancelToken cancelToken,
  ) async {
    final dio = sharedDio();
    Object? lastError;
    for (final endpoint in _feedUrls) {
      try {
        final response = await dio.get<dynamic>(
          endpoint,
          queryParameters: <String, dynamic>{
            'liveStreamId': liveStreamId,
            if (cursor.isNotEmpty) 'cursor': cursor,
          },
          options: Options(
            headers: <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 16; Mobile) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/139.0 Mobile Safari/537.36',
              'Accept': 'application/json, text/plain, */*',
              'Referer': 'https://livev.m.chenzhongtech.com/',
              if (cookie.trim().isNotEmpty) 'cookie': cookie.trim(),
            },
          ),
          cancelToken: cancelToken,
        );
        return response.data;
      } catch (error) {
        if (cancelToken.isCancelled) rethrow;
        lastError = error;
      }
    }
    throw lastError ?? StateError('Kuaishou feed failed');
  }

  /// Parse one feed payload (decoded JSON, a JSON string, or a
  /// double-encoded string) into a batch. Throws [FormatException] /
  /// [StateError] on an invalid shape or a non-1 `result`.
  static KuaishouFeedBatch parseFeedPayload(dynamic raw) {
    dynamic payload = raw;
    for (var depth = 0; depth < 3 && payload is String; depth++) {
      payload = jsonDecode(payload);
    }
    if (payload is Map && payload['data'] is Map) payload = payload['data'];
    if (payload is! Map) {
      throw const FormatException('Kuaishou feed has an invalid shape');
    }
    final result = _asInt(payload['result']);
    if (result != 1) {
      throw StateError(
        'Kuaishou feed rejected the request (result: ${result ?? 'unknown'})',
      );
    }
    final cursor = payload['cursor']?.toString() ?? '';
    final pullSeconds = (_asInt(payload['pullCycleSeconds']) ?? 3).clamp(1, 10);
    final messages = <LiveMessage>[];
    final feeds = payload['liveStreamFeeds'];
    if (feeds is List) {
      for (final feed in feeds) {
        if (feed is! Map) continue;
        if (feed['type']?.toString().toLowerCase() != 'comment') continue;
        final content = feed['content']?.toString().trim() ?? '';
        if (content.isEmpty) continue;
        final author = feed['author'] is Map
            ? feed['author'] as Map
            : const <dynamic, dynamic>{};
        final userName = author['userName']?.toString().trim() ?? '';
        messages.add(
          LiveMessage(
            userName: userName.isEmpty ? '快手用户' : userName,
            message: content,
            color: 0xFFFFFFFF,
          ),
        );
      }
    }
    return KuaishouFeedBatch(
      cursor: cursor,
      pullDelay: Duration(seconds: pullSeconds),
      messages: List<LiveMessage>.unmodifiable(messages),
    );
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
