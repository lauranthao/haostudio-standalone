// TARS request packet — port of Pure Live 3.x
// lib/core/tars/tup/request_packet.dart.
//
// The `displayAsString` body is a no-op here (our vendored codec has no
// TarsDisplayer); the huya_danmaku.dart structs already follow that
// convention.

import 'dart:typed_data';

import '../codec/tars_deep_copyable.dart';
import '../codec/tars_input_stream.dart';
import '../codec/tars_output_stream.dart';
import '../codec/tars_struct.dart';

class RequestPacket extends TarsStruct {
  RequestPacket({
    this.iVersion = 0,
    this.cPacketType = 0,
    this.iMessageType = 0,
    this.iRequestId = 0,
    this.sServantName = '',
    this.sFuncName = '',
    this.sBuffer,
    this.iTimeout = 0,
    this.context,
    this.status,
  });

  String className() => 'RequestPacket';

  int iVersion;
  int cPacketType;
  int iMessageType;
  int iRequestId;
  String sServantName;
  String sFuncName;
  Uint8List? sBuffer;
  int iTimeout;
  Map<String, String>? context;
  Map<String, String>? status;

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(iVersion, 1);
    outputStream.write(cPacketType, 2);
    outputStream.write(iMessageType, 3);
    outputStream.write(iRequestId, 4);
    outputStream.write(sServantName, 5);
    outputStream.write(sFuncName, 6);
    outputStream.write(sBuffer, 7);
    outputStream.write(iTimeout, 8);
    outputStream.write(context, 9);
    outputStream.write(status, 10);
  }

  static Uint8List cacheSBuffer = Uint8List.fromList(<int>[0x0]);
  static Map<String, String> cacheContext = <String, String>{'': ''};
  static Map<String, String> cacheStatus = <String, String>{'': ''};

  @override
  void readFrom(TarsInputStream inputStream) {
    iVersion = inputStream.read<int>(iVersion, 1, false);
    cPacketType = inputStream.read<int>(cPacketType, 2, false);
    iMessageType = inputStream.read<int>(iMessageType, 3, false);
    iRequestId = inputStream.read<int>(iRequestId, 4, false);
    sServantName = inputStream.read<String>(sServantName, 5, false);
    sFuncName = inputStream.read<String>(sFuncName, 6, false);
    sBuffer = inputStream.read<int>(cacheSBuffer, 7, false);
    iTimeout = inputStream.read<int>(iTimeout, 8, false);
    context = inputStream.readMap<String, String>(cacheContext, 9, false);
    status = inputStream.readMap<String, String>(cacheStatus, 10, false);
  }

  @override
  void displayAsString(StringBuffer outputStream, int level) {}

  @override
  Object deepCopy() {
    final o = RequestPacket();
    o.iVersion = iVersion;
    o.cPacketType = cPacketType;
    o.iMessageType = iMessageType;
    o.iRequestId = iRequestId;
    o.sServantName = sServantName;
    o.sFuncName = sFuncName;
    o.sBuffer = sBuffer;
    o.iTimeout = iTimeout;
    if (context != null) {
      o.context = mapDeepCopy<String, String>(context!);
    }
    if (status != null) {
      o.status = mapDeepCopy<String, String>(status!);
    }
    return o;
  }
}
