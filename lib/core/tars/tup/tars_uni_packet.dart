// TARS uni-packet — port of Pure Live 3.x
// lib/core/tars/tup/tars_uni_packet.dart.

import 'dart:typed_data';

import 'const.dart';
import 'uni_packet.dart';

class TarsUniPacket extends UniPacket {
  TarsUniPacket() {
    package.iVersion = TupConst.packetTypeTup3;
    package.cPacketType = TupConst.packetTypeTarsNormal;
    package.iMessageType = 0;
    package.iTimeout = 0;
    package.sBuffer = Uint8List.fromList(<int>[0x0]);
    package.context = <String, String>{};
    package.status = <String, String>{};
  }

  void setTarsVersion(int version) {
    setVersion(version);
  }

  void setTarsPacketType(int packetType) {
    package.cPacketType = packetType;
  }

  void setTarsMessageType(int messageType) {
    package.iMessageType = messageType;
  }

  void setTarsTimeout(int timeout) {
    package.iTimeout = timeout;
  }

  void setTarsBuffer(Uint8List buffer) {
    package.sBuffer = buffer;
  }

  void setTarsContext(Map<String, String> context) {
    package.context = context;
  }

  void setTarsStatus(Map<String, String> status) {
    package.status = status;
  }

  int getTarsVersion() => package.iVersion;

  int getTarsPacketType() => package.cPacketType;

  int getTarsMessageType() => package.iMessageType;

  int getTarsTimeout() => package.iTimeout;

  Uint8List? getTarsBuffer() => package.sBuffer;

  Map<String, String>? getTarsContext() => package.context;

  Map<String, String>? getTarsStatus() => package.status;

  int getTarsResultCode() {
    var result = 0;
    try {
      final rcode = package.status?['STATUS_RESULT_CODE'];
      result = rcode != null ? int.tryParse(rcode) ?? 0 : 0;
    } catch (_) {
      return 0;
    }
    return result;
  }

  String getTarsResultDesc() => package.status?['STATUS_RESULT_DESC'] ?? '';
}
