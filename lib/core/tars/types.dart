// Huya TARS user/message types — port of the HuyaUserId + MessageUser
// structs in Pure Live 3.x lib/core/tars/types.dart.
//
// Only the structs the Huya WUP calls need are ported (GetLivingInfoReq
// is not). `displayAsString` is a no-op — our vendored codec has no
// TarsDisplayer; huya_danmaku.dart follows the same convention.

import 'codec/tars_input_stream.dart';
import 'codec/tars_output_stream.dart';
import 'codec/tars_struct.dart';

class HuyaUserId extends TarsStruct {
  int lUid = 0;
  String sGuid = '';
  String sToken = '';
  String sHuYaUA = '';
  String sCookie = '';
  int iTokenType = 0;
  String sDeviceInfo = '';
  String sQIMEI = '';

  @override
  void readFrom(TarsInputStream tarsInputStream) {
    lUid = tarsInputStream.read(lUid, 0, false);
    sGuid = tarsInputStream.read(sGuid, 1, false);
    sToken = tarsInputStream.read(sToken, 2, false);
    sHuYaUA = tarsInputStream.read(sHuYaUA, 3, false);
    sCookie = tarsInputStream.read(sCookie, 4, false);
    iTokenType = tarsInputStream.read(iTokenType, 5, false);
    sDeviceInfo = tarsInputStream.read(sDeviceInfo, 6, false);
    sQIMEI = tarsInputStream.read(sQIMEI, 7, false);
  }

  @override
  void writeTo(TarsOutputStream tarsOutputStream) {
    tarsOutputStream.write(lUid, 0);
    tarsOutputStream.write(sGuid, 1);
    tarsOutputStream.write(sToken, 2);
    tarsOutputStream.write(sHuYaUA, 3);
    tarsOutputStream.write(sCookie, 4);
    tarsOutputStream.write(iTokenType, 5);
    tarsOutputStream.write(sDeviceInfo, 6);
    tarsOutputStream.write(sQIMEI, 7);
  }

  @override
  Object deepCopy() {
    return HuyaUserId()
      ..lUid = lUid
      ..sGuid = sGuid
      ..sToken = sToken
      ..sHuYaUA = sHuYaUA
      ..sCookie = sCookie
      ..iTokenType = iTokenType
      ..sDeviceInfo = sDeviceInfo
      ..sQIMEI = sQIMEI;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class MessageUser extends TarsStruct {
  String sNick = '';
  String sAvatar = '';

  @override
  void readFrom(TarsInputStream tarsInputStream) {
    sNick = tarsInputStream.read(sNick, 1, false);
    sAvatar = tarsInputStream.read(sAvatar, 2, false);
  }

  @override
  void writeTo(TarsOutputStream tarsOutputStream) {
    tarsOutputStream.write(sNick, 1);
    tarsOutputStream.write(sAvatar, 2);
  }

  @override
  Object deepCopy() {
    return MessageUser()
      ..sNick = sNick
      ..sAvatar = sAvatar;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
