// Huya search live-network smoke test.
//
// No existing test file covers Huya search (huya_site_test.dart has
// none) — the live search page depends on it, so prove the real API
// answers. Best-effort like the other live-network tests (douyu /
// bilibili): the API is real, the keyword is a top game, so a
// non-empty answer is expected.
//
// This MUST stay a separate file with no TestWidgetsFlutterBinding:
// that binding mocks HttpClient to return 400 for every request,
// which breaks real network (proven: this test returned [] when it
// lived in live_search_test.dart). Keep it binding-free like
// douyu_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/shared/platforms/huya/huya_site.dart';

void main() {
  test('searchRooms returns real live rooms', () async {
    final rooms = await HuyaSite().searchRooms('王者荣耀');
    expect(rooms, isNotEmpty);
    expect(rooms.every((r) => r.roomId.isNotEmpty), isTrue);
    expect(rooms.every((r) => r.platform == 'huya'), isTrue);
  });
}
