// P1-P5: timeouts must CANCEL the underlying Dio request, not just
// stop waiting for it. A cancelled request is not a failure: nothing
// is recorded against the platform/source.
//
// Both tests use fakeAsync: the hanging fakes only resolve when their
// CancelToken is cancelled, so the test proves the token was actually
// cancelled at the timeout — not merely that the caller gave up waiting.

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/song_search_service.dart';
import 'package:standalone/services/video/cms_client.dart';
import 'package:standalone/features/video/video_models.dart';

/// Platform search that never answers on its own — it only returns
/// once its CancelToken is cancelled.
class _HangingApi extends MusicApi {
  CancelToken? seenToken;

  @override
  Future<List<Song>> searchOne(
    MusicPlatform pf,
    String q, {
    CancelToken? cancelToken,
  }) {
    seenToken = cancelToken;
    return cancelToken!.whenCancel.then((_) => <Song>[]);
  }
}

/// Fake LX engine: no real JS runtime, no script legs.
class _NoScriptEngine extends LxScriptEngine {
  @override
  Future<void> ensureInitialized() async {}

  @override
  List<({String scriptId, String scriptName})> searchLegsFor(
    MusicPlatform platform,
  ) => const [];

  @override
  Future<List<Map<String, dynamic>>> search({
    required String scriptId,
    required String platform,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async => const [];
}

void main() {
  test('music leg: 5 s cap cancels the platform request', () {
    fakeAsync((async) {
      final api = _HangingApi();
      final service = SongSearchService(
        api: api,
        scriptEngine: _NoScriptEngine(),
      );
      var done = false;
      service
          .searchAllStream('test', onlyPlatform: MusicPlatform.wy)
          .listen((_) {}, onDone: () => done = true);
      async.flushMicrotasks();
      expect(api.seenToken, isNotNull, reason: 'leg got a token');
      expect(api.seenToken!.isCancelled, isFalse);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(
        api.seenToken!.isCancelled,
        isTrue,
        reason: 'the 5 s leg cap must cancel the Dio request',
      );
      expect(done, isTrue, reason: 'cancelled leg settles, stream closes');
    });
  });

  test('video fanOut: overall cap cancels the in-flight source jobs', () {
    fakeAsync((async) {
      final seenTokens = <CancelToken>[];
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        // Sequential fallback (no token): answer empty at once.
        if (cancelToken == null) return {'list': []};
        seenTokens.add(cancelToken);
        // Hang until cancelled — proves the token is really cancelled.
        await cancelToken.whenCancel;
        throw StateError('cancelled');
      }

      final client = CmsClient(
        sources: const [
          VideoSource(
            id: 1,
            name: 'A',
            apiUrl: 'http://a.example.com/api.php/provide/vod',
            kind: 'play',
            sort: 1,
          ),
          VideoSource(
            id: 2,
            name: 'B',
            apiUrl: 'http://b.example.com/api.php/provide/vod',
            kind: 'play',
            sort: 2,
          ),
        ],
        fetcher: fetcher,
      );
      List<VideoItem>? outcome;
      Object? failure;
      client
          .search('x')
          .then((v) => outcome = v, onError: (e, _) => failure = e);
      async.flushMicrotasks();
      expect(seenTokens.length, 2);
      expect(seenTokens.every((t) => !t.isCancelled), isTrue);
      // Page-1 overall cap is 3.5 s.
      async.elapse(const Duration(milliseconds: 3500));
      async.flushMicrotasks();
      expect(
        seenTokens.every((t) => t.isCancelled),
        isTrue,
        reason: 'the overall cap must cancel the in-flight jobs',
      );
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(failure, isNull);
      expect(outcome, isNotNull);
      expect(outcome, isEmpty);
    });
  });
}
