// Emby connect page — client + model tests (build 29, C group).
//
// Hermetic: every test drives EmbyClient with injected canned
// fetcher/mutator — zero network. All credentials below are FAKE
// fixture values, never real ones.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

EmbyResponse okJson(dynamic json) =>
    EmbyResponse(statusCode: 200, json: json);

/// Canned mutator: answers by URL substring, records everything.
class CannedEmbyMutator {
  CannedEmbyMutator(this._answers);

  final Map<String, EmbyResponse> _answers;
  final List<String> seenMethods = [];
  final List<String> seenUrls = [];
  final List<Map<String, String>?> seenHeaders = [];
  final List<Map<String, dynamic>?> seenBodies = [];
  int calls = 0;

  Future<EmbyResponse> call(
    String method,
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? jsonBody,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    calls++;
    seenMethods.add(method);
    seenUrls.add(url);
    seenHeaders.add(headers);
    seenBodies.add(jsonBody);
    for (final entry in _answers.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

/// Canned fetcher: answers by URL substring, 404s anything else.
class CannedEmbyFetcher {
  CannedEmbyFetcher(this._answers);

  final Map<String, EmbyResponse> _answers;
  final List<String> seenUrls = [];
  final List<Map<String, String>?> seenHeaders = [];

  Future<EmbyResponse> call(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seenUrls.add(url);
    seenHeaders.add(headers);
    for (final entry in _answers.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

const _keyConfig = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'key-fake-123',
);

const _tokenConfig = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: '',
  userId: 'user-9',
  username: 'chen',
  accessToken: 'tok-fake-abc',
);

void main() {
  group('AuthenticateByName', () {
    test('200 returns token + user id; POST body + auth header', () async {
      final mutator = CannedEmbyMutator({
        '/Users/AuthenticateByName': okJson({
          'AccessToken': 'tok-fake-abc',
          'User': {'Id': 'user-9', 'Name': 'chen'},
        }),
      });
      final client = EmbyClient(config: _keyConfig, mutator: mutator.call);
      final result = await client.authenticateByName(
        username: 'chen',
        password: 'pw-fake',
      );
      expect(result.ok, isTrue);
      expect(result.accessToken, 'tok-fake-abc');
      expect(result.userId, 'user-9');
      expect(result.userName, 'chen');
      expect(mutator.seenMethods.single, 'POST');
      expect(mutator.seenUrls.single,
          contains('/emby/Users/AuthenticateByName'));
      expect(mutator.seenBodies.single?['Username'], 'chen');
      expect(mutator.seenBodies.single?['Pw'], 'pw-fake');
      expect(
        mutator.seenHeaders.single?['X-Emby-Authorization'],
        contains('HAo Studio'),
      );
      // The password never lands in a URL.
      expect(mutator.seenUrls.single.contains('pw-fake'), isFalse);
    });

    test('401 => wrong name/password, account wording', () async {
      final mutator = CannedEmbyMutator({
        '/Users/AuthenticateByName':
            const EmbyResponse(statusCode: 401, json: {}),
      });
      final client = EmbyClient(config: _keyConfig, mutator: mutator.call);
      final result = await client.authenticateByName(
        username: 'chen',
        password: 'wrong-fake',
      );
      expect(result.ok, isFalse);
      expect(result.errorKind, EmbyErrorKind.unauthorized);
      expect(result.errorMessage, 'Emby 用户名或密码不对，请重新登录');
    });

    test('404 on /emby retries the root prefix', () async {
      final mutator = CannedEmbyMutator({
        '/emby/Users/AuthenticateByName':
            const EmbyResponse(statusCode: 404, json: {}),
        '/Users/AuthenticateByName': okJson({
          'AccessToken': 'tok-fake-root',
          'User': {'Id': 'user-2', 'Name': 'chen'},
        }),
      });
      final client = EmbyClient(config: _keyConfig, mutator: mutator.call);
      final result = await client.authenticateByName(
        username: 'chen',
        password: 'pw-fake',
      );
      expect(result.ok, isTrue);
      expect(result.accessToken, 'tok-fake-root');
      expect(mutator.seenUrls.length, 2);
      expect(mutator.seenUrls[1], isNot(contains('/emby/')));
    });

    test('baseUrl override tries that line, then restores primary',
        () async {
      final mutator = CannedEmbyMutator({
        '/Users/AuthenticateByName': okJson({
          'AccessToken': 'tok-fake-abc',
          'User': {'Id': 'user-9', 'Name': 'chen'},
        }),
      });
      final client = EmbyClient(config: _keyConfig, mutator: mutator.call);
      final result = await client.authenticateByName(
        username: 'chen',
        password: 'pw-fake',
        baseUrl: 'http://backup-fake:8096',
      );
      expect(result.ok, isTrue);
      expect(mutator.seenUrls.single, contains('backup-fake'));
      // Override cleared: later calls use the configured baseUrl.
      expect(client.streamUrl('m1'), contains('127.0.0.1'));
    });

    test('missing token/user in 200 => not ok', () async {
      final mutator = CannedEmbyMutator({
        '/Users/AuthenticateByName': okJson({'AccessToken': ''}),
      });
      final client = EmbyClient(config: _keyConfig, mutator: mutator.call);
      final result = await client.authenticateByName(
        username: 'chen',
        password: 'pw-fake',
      );
      expect(result.ok, isFalse);
      expect(result.errorMessage, 'Emby 登录没有返回有效的凭证');
    });
  });

  group('token auth on the wire', () {
    test('token config sends the token, never the key', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info':
            okJson({'ServerName': 'Home', 'Version': '4.8.0'}),
      });
      final client =
          EmbyClient(config: _tokenConfig, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(fetcher.seenHeaders.first?['X-Emby-Token'], 'tok-fake-abc');
      expect(fetcher.seenUrls.every((u) => !u.contains('api_key')), isTrue);
      expect(client.streamUrl('m1'), contains('api_key=tok-fake-abc'));
      // Known user id: GET /Users is skipped (a user token cannot
      // read it on many servers) and the probe still succeeds.
      expect(fetcher.seenUrls.any((u) => u.contains('/Users')), isFalse);
    });

    test('probe 401 with a token uses the account wording', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info': const EmbyResponse(statusCode: 401, json: {}),
      });
      final client =
          EmbyClient(config: _tokenConfig, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isFalse);
      expect(result.errorMessage, 'Emby 用户名或密码不对，请重新登录');
    });

    test('key config still sends the key', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info':
            okJson({'ServerName': 'Home', 'Version': '4.8.0'}),
        '/Users': okJson({
          'Items': [
            {'Id': 'user-1', 'Name': 'chen'},
          ],
        }),
      });
      final client = EmbyClient(config: _keyConfig, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(fetcher.seenHeaders.first?['X-Emby-Token'], 'key-fake-123');
      expect(result.users.map((u) => u.id), ['user-1']);
    });

    test('probe tolerates a failing /Users fetch in key mode', () async {
      final fetcher = CannedEmbyFetcher({
        '/System/Info':
            okJson({'ServerName': 'Home', 'Version': '4.8.0'}),
        '/Users': const EmbyResponse(statusCode: 500, json: {}),
      });
      final client = EmbyClient(config: _keyConfig, fetcher: fetcher.call);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(result.users, isEmpty);
    });
  });

  group('fallback lines', () {
    test('probe tries fallbacks and reports the working base', () async {
      Future<EmbyResponse> hostAware(
        String url, {
        Map<String, String>? headers,
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        if (url.contains('backup-fake')) {
          if (url.contains('/System/Info')) {
            return okJson({'ServerName': 'Backup', 'Version': '4.8.0'});
          }
          if (url.contains('/Users')) {
            return okJson({'Items': <dynamic>[]});
          }
        }
        return const EmbyResponse(statusCode: 404, json: {});
      }

      const config = EmbyServerConfig(
        baseUrl: 'http://primary-fake:8096',
        apiKey: 'key-fake-123',
        fallbackUrls: ['http://backup-fake:8096'],
      );
      final client = EmbyClient(config: config, fetcher: hostAware);
      final result = await client.probe();
      expect(result.ok, isTrue);
      expect(result.serverName, 'Backup');
      expect(result.workingBaseUrl, 'http://backup-fake:8096');
    });
  });

  group('report gate (数据上报）', () {
    test('off => no request at all for automatic reports', () async {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        userId: 'user-1',
        reportProgress: false,
      );
      final mutator = CannedEmbyMutator({
        'PlayingItems': okJson({}),
        'PlayedItems': okJson({}),
        'FavoriteItems': okJson({}),
      });
      final client = EmbyClient(config: config, mutator: mutator.call);
      expect(await client.reportPlaybackStart('m1'), isFalse);
      expect(
        await client.reportPlaybackProgress('m1', positionSeconds: 30),
        isFalse,
      );
      expect(await client.reportPlaybackStopped('m1'), isFalse);
      expect(await client.markPlayed('m1'), isFalse);
      expect(mutator.calls, 0);
      // Explicit user action is NOT gated: tapping favorite is the
      // user asking the server to record it.
      expect(await client.setFavorite('m1', true), isTrue);
      expect(mutator.calls, 1);
    });

    test('on (default) => automatic reports are sent', () async {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        userId: 'user-1',
      );
      final mutator = CannedEmbyMutator({
        'PlayingItems': okJson({}),
        'PlayedItems': okJson({}),
      });
      final client = EmbyClient(config: config, mutator: mutator.call);
      expect(await client.reportPlaybackStart('m1'), isTrue);
      expect(await client.markPlayed('m1'), isTrue);
      expect(mutator.calls, 2);
    });
  });

  group('STRM direct', () {
    EmbyStreamFacts factsWithPath(String path) =>
        EmbyStreamFacts.fromMediaSources([
          {
            'Container': 'mkv',
            'Path': path,
            'MediaStreams': <dynamic>[],
          },
        ]);

    test('on + remote http path => the remote URL directly', () {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        strmDirect: true,
      );
      final client = EmbyClient(config: config);
      final url = client.streamUrl(
        'm1',
        facts: factsWithPath('https://cdn-fake.example.com/movie.mkv'),
      );
      expect(url, 'https://cdn-fake.example.com/movie.mkv');
    });

    test('off => server stream endpoint', () {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        strmDirect: false,
      );
      final client = EmbyClient(config: config);
      final url = client.streamUrl(
        'm1',
        facts: factsWithPath('https://cdn-fake.example.com/movie.mkv'),
      );
      expect(url, contains('/Videos/m1/stream'));
    });

    test('on + local server path => server stream endpoint', () {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        strmDirect: true,
      );
      final client = EmbyClient(config: config);
      final url = client.streamUrl(
        'm1',
        facts: factsWithPath('/media/movie.strm'),
      );
      expect(url, contains('/Videos/m1/stream'));
    });
  });

  group('public line check', () {
    test('200 + ServerName => true; 404 => false', () async {
      final okFetcher = CannedEmbyFetcher({
        '/System/Info/Public':
            okJson({'ServerName': 'Home', 'Version': '4.8.0'}),
      });
      final client = EmbyClient(config: _keyConfig, fetcher: okFetcher.call);
      expect(
        await client.checkPublicLine('http://127.0.0.1:8096'),
        isTrue,
      );
      final deadFetcher = CannedEmbyFetcher({});
      final deadClient =
          EmbyClient(config: _keyConfig, fetcher: deadFetcher.call);
      expect(
        await deadClient.checkPublicLine('http://127.0.0.1:8096'),
        isFalse,
      );
    });
  });

  group('migration + address parse', () {
    test('legacy baseUrl + apiKey loads and splits for editing', () {
      final config = EmbyServerConfig.fromJson({
        'baseUrl': 'http://192.168.1.10:8096/emby',
        'apiKey': 'key-fake-123',
      });
      expect(config.isConfigured, isTrue);
      expect(config.reportProgress, isTrue);
      expect(config.strmDirect, isFalse);
      expect(config.reminderDays, 0);
      expect(config.fallbackUrls, isEmpty);
      final address = EmbyServerAddress.parse(config.baseUrl);
      expect(address.host, '192.168.1.10');
      expect(address.port, 8096);
      expect(address.path, '/emby');
      expect(address.useHttps, isFalse);
      expect(address.baseUrl, 'http://192.168.1.10:8096/emby');
    });

    test('parse bare host / full https URL / compose round-trip', () {
      final bare = EmbyServerAddress.parse('example-fake.com');
      expect(bare.host, 'example-fake.com');
      expect(bare.port, 8096);
      expect(bare.useHttps, isFalse);
      expect(bare.path, '');
      final https = EmbyServerAddress.parse('https://emby-fake.example.com');
      expect(https.useHttps, isTrue);
      expect(https.port, 443);
      expect(
        EmbyServerAddress.compose(
          useHttps: true,
          host: 'h',
          port: 8096,
          path: '/emby',
        ),
        'https://h:8096/emby',
      );
      expect(
        EmbyServerAddress.compose(
          useHttps: false,
          host: 'h',
          port: 8096,
          path: '',
        ),
        'http://h:8096',
      );
      expect(
        EmbyServerAddress.compose(
          useHttps: false,
          host: '',
          port: 8096,
          path: '',
        ),
        '',
      );
    });

    test('new fields survive a JSON round-trip', () {
      const config = EmbyServerConfig(
        baseUrl: 'http://127.0.0.1:8096',
        apiKey: 'key-fake-123',
        name: '家里',
        note: '到期 2027-01',
        username: 'chen',
        accessToken: 'tok-fake-abc',
        deviceId: 'device-fake-1',
        serverName: 'Home',
        serverVersion: '4.8.0',
        reportProgress: false,
        strmDirect: true,
        fallbackUrls: ['http://backup-fake:8096'],
        reminderDays: 7,
        lastPlayedAtMs: 1700000000000,
      );
      final back = EmbyServerConfig.fromJson(config.toJson());
      expect(back.name, '家里');
      expect(back.note, '到期 2027-01');
      expect(back.username, 'chen');
      expect(back.accessToken, 'tok-fake-abc');
      expect(back.deviceId, 'device-fake-1');
      expect(back.serverName, 'Home');
      expect(back.reportProgress, isFalse);
      expect(back.strmDirect, isTrue);
      expect(back.fallbackUrls, ['http://backup-fake:8096']);
      expect(back.reminderDays, 7);
      expect(back.lastPlayedAtMs, 1700000000000);
      expect(back.authToken, 'tok-fake-abc');
      expect(back.usesPasswordAuth, isTrue);
    });

    test('address-only config is not configured', () {
      const config = EmbyServerConfig(baseUrl: 'http://127.0.0.1:8096', apiKey: '');
      expect(config.isConfigured, isFalse);
    });

    test('device ids are 32 hex chars and differ', () {
      final a = EmbyServerConfig.newDeviceId();
      final b = EmbyServerConfig.newDeviceId();
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });
  });

  group('reminder threshold', () {
    test('off / never played / within threshold / overdue', () {
      final now = DateTime(2026, 11, 22, 9, 0);
      expect(
        EmbyReminder.shouldRemind(
          lastPlayedAtMs: now.millisecondsSinceEpoch,
          thresholdDays: 0,
          now: now,
        ),
        isFalse,
      );
      expect(
        EmbyReminder.shouldRemind(
          lastPlayedAtMs: null,
          thresholdDays: 7,
          now: now,
        ),
        isFalse,
      );
      expect(
        EmbyReminder.shouldRemind(
          lastPlayedAtMs: now
              .subtract(const Duration(days: 3))
              .millisecondsSinceEpoch,
          thresholdDays: 7,
          now: now,
        ),
        isFalse,
      );
      expect(
        EmbyReminder.shouldRemind(
          lastPlayedAtMs: now
              .subtract(const Duration(days: 8))
              .millisecondsSinceEpoch,
          thresholdDays: 7,
          now: now,
        ),
        isTrue,
      );
      expect(EmbyReminder.label(0), '关闭');
      expect(EmbyReminder.label(7), '7 天');
    });
  });
}
