// Super-chat message-board response — port of Pure Live 3.x
// lib/core/tars/get_game_event_message_board_rsp.dart.

import 'codec/tars_input_stream.dart';
import 'codec/tars_output_stream.dart';
import 'codec/tars_struct.dart';
import 'game_event_message_board_panel.dart';

class GetGameEventMessageBoardRsp extends TarsStruct {
  GameEventMessageBoardPanel tMessageBoardPanel =
      GameEventMessageBoardPanel();

  @override
  void readFrom(TarsInputStream tarsInputStream) {
    tMessageBoardPanel = tarsInputStream.read(tMessageBoardPanel, 1, false);
  }

  @override
  void writeTo(TarsOutputStream tarsOutputStream) {
    tarsOutputStream.write(tMessageBoardPanel, 1);
  }

  @override
  Object deepCopy() {
    return GetGameEventMessageBoardRsp()
      ..tMessageBoardPanel =
          tMessageBoardPanel.deepCopy() as GameEventMessageBoardPanel;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
