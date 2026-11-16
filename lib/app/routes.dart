// App routes (GetX named routes).
//
// The live room is also pushed directly via Get.to(() => LiveRoomPage)
// from the live tab; the named route exists so deep links / future
// navigation can open a room by platform + room id.

import 'package:get/get.dart';

import '../core/models/live_models.dart';
import '../domains/live/presentation/playback/live_room_page.dart';
import '../widgets/app_shell.dart';

class AppRoutes {
  AppRoutes._();

  static const String home = '/';
  static const String liveRoom = '/live-room';

  static List<GetPage<dynamic>> get pages => [
        GetPage<dynamic>(name: home, page: () => const AppShell()),
        GetPage<dynamic>(
          name: liveRoom,
          page: () {
            // `as Map` throws when a deep link / caller passes a
            // non-Map argument (e.g. a plain room-id string); fall
            // back to empty args instead of crashing the route.
            final args = Get.arguments;
            final map = args is Map ? args : const <String, dynamic>{};
            return LiveRoomPage(
              room: LiveRoom(
                roomId: map['roomId']?.toString() ?? '',
                platform: map['platform']?.toString() ?? 'bilibili',
                title: map['title']?.toString() ?? '',
              ),
              // Live entry is ALWAYS portrait (fix 2).
            );
          },
        ),
      ];
}
