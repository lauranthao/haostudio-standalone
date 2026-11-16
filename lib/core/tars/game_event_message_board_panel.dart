// Super-chat message-board panel — port of Pure Live 3.x
// lib/core/tars/game_event_message_board_panel.dart.

import 'codec/tars_input_stream.dart';
import 'codec/tars_output_stream.dart';
import 'codec/tars_struct.dart';
import 'game_event_message_board_info.dart';

class GameEventMessageBoardPanel extends TarsStruct {
  List<GameEventMessageBoardInfo> vGameEventMessageBoardInfo = [
    GameEventMessageBoardInfo(),
  ];

  @override
  void readFrom(TarsInputStream tarsInputStream) {
    vGameEventMessageBoardInfo = tarsInputStream
        .read(vGameEventMessageBoardInfo, 1, false)
        .cast<GameEventMessageBoardInfo>();
  }

  @override
  void writeTo(TarsOutputStream tarsOutputStream) {
    tarsOutputStream.write(vGameEventMessageBoardInfo, 1);
  }

  @override
  Object deepCopy() {
    return GameEventMessageBoardPanel()
      ..vGameEventMessageBoardInfo = vGameEventMessageBoardInfo
          .map((e) => e.deepCopy() as GameEventMessageBoardInfo)
          .toList();
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
