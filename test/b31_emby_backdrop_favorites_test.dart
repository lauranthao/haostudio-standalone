// Build 31 Emby batch tests:
// - Backdrop art: items with an ImageTags['Backdrop'] expose it on
//   VideoItem.backdrop as an /Images/Backdrop URL; without one it is ''.
// - favorites() queries Filters=IsFavorite; byGenre() sends Genres.
// - VideoItem round-trips backdrop through fromJson/toJson.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

Map<String, dynamic> itemJson({
  required String id,
  String type = 'Movie',
  String name = 'Test Film',
  String? primaryTag,
  String? backdropTag,
}) {
  final tags = <String, String>{
    if (primaryTag != null) 'Primary': primaryTag,
    if (backdropTag != null) 'Backdrop': backdropTag,
  };
  return <String, dynamic>{
    'Id': id,
    'Name': name,
    'Type': type,
    'ImageTags': tags,
    'UserData': {'Played': false, 'IsFavorite': false},
  };
}

EmbyResponse okJson(dynamic json) =>
    EmbyResponse(statusCode: 200, json: json);

/// Minimal canned fetcher (same shape as emby_client_test.dart).
class _Fetcher {
  _Fetcher(this._answers);

  final Map<String, EmbyResponse> _answers;
  final List<String> seenUrls = [];

  Future<EmbyResponse> call(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    seenUrls.add(url);
    for (final entry in _answers.entries) {
      if (url.contains(entry.key)) return entry.value;
    }
    return const EmbyResponse(statusCode: 404, json: {});
  }
}

void main() {
  test('movies() exposes Backdrop art and keeps the Primary poster', () async {
    final fetcher = _Fetcher({
      '/Items': okJson({
        'Items': [
          itemJson(id: 'm1', primaryTag: 'p1', backdropTag: 'b1'),
          itemJson(id: 'm2', primaryTag: 'p2'),
        ],
        'TotalRecordCount': 2,
      }),
    });
    final client = EmbyClient(config: _config, fetcher: fetcher.call);
    final page = await client.movies();
    expect(page.items.length, 2);
    final withBackdrop = page.items[0];
    expect(withBackdrop.pic, contains('/Images/Primary'));
    expect(withBackdrop.pic, contains('m1'));
    expect(withBackdrop.backdrop, contains('/Images/Backdrop'));
    expect(withBackdrop.backdrop, contains('m1'));
    // No Backdrop tag on the server item -> '' (caller falls back to pic).
    expect(page.items[1].backdrop, isEmpty);
    expect(page.items[1].pic, contains('/Images/Primary'));
  });

  test('favorites() filters IsFavorite across movies and series', () async {
    final fetcher = _Fetcher({
      '/Items': okJson({'Items': <dynamic>[], 'TotalRecordCount': 0}),
    });
    final client = EmbyClient(config: _config, fetcher: fetcher.call);
    await client.favorites();
    expect(fetcher.seenUrls.length, 1);
    final url = fetcher.seenUrls.single;
    expect(url, contains('Filters=IsFavorite'));
    expect(url, contains('IncludeItemTypes=Movie%2CVideo%2CSeries'));
  });

  test('byGenre() sends the Genres filter', () async {
    final fetcher = _Fetcher({
      '/Items': okJson({'Items': <dynamic>[], 'TotalRecordCount': 0}),
    });
    final client = EmbyClient(config: _config, fetcher: fetcher.call);
    await client.byGenre('动作');
    expect(fetcher.seenUrls.length, 1);
    expect(fetcher.seenUrls.single, contains('Genres='));
    expect(
      fetcher.seenUrls.single,
      contains(Uri.encodeComponent('动作')),
    );
    expect(
      fetcher.seenUrls.single,
      contains('IncludeItemTypes=Movie%2CVideo%2CSeries'),
    );
  });

  test('VideoItem round-trips backdrop through fromJson/toJson', () {
    const item = VideoItem(
      source: 'emby',
      sourceName: 'Emby',
      vodId: 'm1',
      name: 'Test Film',
      pic: 'http://x/Primary',
      backdrop: 'http://x/Backdrop',
    );
    final restored = VideoItem.fromJson(item.toJson());
    expect(restored.backdrop, 'http://x/Backdrop');
    expect(restored.pic, 'http://x/Primary');
    expect(item.copyWith().backdrop, 'http://x/Backdrop');
    expect(item.copyWith(backdrop: 'http://x/Other').backdrop, 'http://x/Other');
  });
}
