// Hot search service: real platform data only, never fabricated.
//
// Parsing runs on canned JSON (the shapes curl-verified live on
// 2026-11-18); platforms with no working endpoint return [] without
// touching the network.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/hot_search_service.dart';
import 'package:standalone/services/music/music_models.dart';

void main() {
  group('HotSearchService.parseNetEase', () {
    test('reads result.hots[].first, trims, drops empties, honours limit',
        () {
      final data = jsonDecode('''
        {"code":200,"result":{"hots":[
          {"first":"哪里都是你"},
          {"first":"  带空格  "},
          {"first":""},
          {"first":"第三首"},
          {"first":"第四首"}
        ]}}
      ''') as Map<String, dynamic>;
      expect(
        HotSearchService.parseNetEase(data, 3),
        ['哪里都是你', '带空格', '第三首'],
      );
    });

    test('malformed payloads -> []', () {
      expect(HotSearchService.parseNetEase({}, 10), isEmpty);
      expect(
        HotSearchService.parseNetEase({'result': {'hots': 'nope'}}, 10),
        isEmpty,
      );
      expect(
        HotSearchService.parseNetEase({'result': 'nope'}, 10),
        isEmpty,
      );
    });
  });

  group('HotSearchService.parseQQ', () {
    test('reads data.hotkey[].k, trims trailing spaces, honours limit',
        () {
      final data = jsonDecode('''
        {"code":0,"data":{"hotkey":[
          {"k":"我们的歌 ","n":765562},
          {"k":"周杰伦","n":123},
          {"k":"  ","n":1},
          {"k":"林俊杰 ","n":99}
        ]}}
      ''') as Map<String, dynamic>;
      expect(
        HotSearchService.parseQQ(data, 2),
        ['我们的歌', '周杰伦'],
      );
    });

    test('malformed payloads -> []', () {
      expect(HotSearchService.parseQQ({}, 10), isEmpty);
      expect(
        HotSearchService.parseQQ({'data': {'hotkey': 'nope'}}, 10),
        isEmpty,
      );
    });
  });

  group('HotSearchService.hotSearch', () {
    test('platforms with no working endpoint return [] without network',
        () async {
      final service = HotSearchService();
      expect(await service.hotSearch(MusicPlatform.kg), isEmpty);
      expect(await service.hotSearch(MusicPlatform.kw), isEmpty);
      expect(await service.hotSearch(MusicPlatform.mg), isEmpty);
    });
  });
}
