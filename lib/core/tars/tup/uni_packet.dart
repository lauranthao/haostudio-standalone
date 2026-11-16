// TUP packet framing — port of Pure Live 3.x
// lib/core/tars/tup/uni_packet.dart, TUP3 only.
//
// encode(): attribute map (tag 0) becomes RequestPacket.sBuffer, the
// packet is TARS-serialised, and a 4-byte big-endian total length is
// prepended. decode() reverses it. Upstream builds the length prefix
// with its vendored WriteBuffer copy; the 4 bytes are written directly
// here instead (same wire bytes, no extra file).

import 'dart:typed_data';

import '../codec/tars_input_stream.dart';
import '../codec/tars_output_stream.dart';
import 'const.dart';
import 'request_packet.dart';
import 'uni_attribute.dart';

class UniPacket extends UniAttribute {
  static const int kUniPacketHeadSize = 4;

  RequestPacket package = RequestPacket();

  String get servantName => package.sServantName;

  set servantName(String value) {
    package.sServantName = value;
  }

  String get funcName => package.sFuncName;

  set funcName(String value) {
    package.sFuncName = value;
  }

  int get requestId => package.iRequestId;

  set requestId(int value) {
    package.iRequestId = value;
  }

  UniPacket() {
    package.iVersion = TupConst.packetTypeTup3;
  }

  void setVersion(int iVer) {
    version = iVer;
    package.iVersion = iVer;
  }

  int getVersion() => package.iVersion;

  @override
  Uint8List encode() {
    if (package.sServantName.compareTo('') == 0) {
      throw ArgumentError('servantName can not be null');
    }
    if (package.sFuncName.compareTo('') == 0) {
      throw ArgumentError('funcName can not be null');
    }

    final attributeStream = TarsOutputStream();
    attributeStream.setServerEncoding(encodeName);
    attributeStream.write(newData, 0);
    package.sBuffer = attributeStream.toUint8List();

    final packetStream = TarsOutputStream();
    packetStream.setServerEncoding(encodeName);
    writeTo(packetStream);
    final body = packetStream.toUint8List();
    final size = body.lengthInBytes;

    final out = Uint8List(kUniPacketHeadSize + size);
    final header = ByteData.view(out.buffer);
    header.setUint32(0, size + kUniPacketHeadSize, Endian.big);
    out.setRange(kUniPacketHeadSize, out.length, body);
    return out;
  }

  @override
  void decode(Uint8List buffer, {int index = 0}) {
    if (buffer.lengthInBytes < kUniPacketHeadSize) {
      throw ArgumentError('Decode namespace must include size head');
    }
    try {
      var inputStream =
          TarsInputStream(buffer, pos: kUniPacketHeadSize + index);
      inputStream.setServerEncoding(encodeName);
      readFrom(inputStream);

      version = package.iVersion;

      inputStream = TarsInputStream(package.sBuffer);
      inputStream.setServerEncoding(encodeName);

      newData = inputStream.readMap<String, Uint8List>(
        <String, Uint8List>{'': Uint8List.fromList(<int>[0x0])},
        0,
        false,
      );
    } catch (_) {
      // A failed decode is a failed WUP call, never a crash — callers
      // catch and fall back.
      rethrow;
    }
  }

  @override
  void writeTo(TarsOutputStream outputStream) {
    package.writeTo(outputStream);
  }

  @override
  void readFrom(TarsInputStream inputStream) {
    package.readFrom(inputStream);
  }
}
