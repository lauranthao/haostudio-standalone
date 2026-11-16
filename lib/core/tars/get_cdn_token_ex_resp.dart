// getCdnTokenInfoEx response — port of Pure Live 3.x
// lib/core/tars/get_cdn_token_ex_resp.dart.

import 'codec/tars_input_stream.dart';
import 'codec/tars_output_stream.dart';
import 'codec/tars_struct.dart';

class GetCdnTokenExResp extends TarsStruct {
  String sFlvToken = ''; // tag 0
  int iExpireTime = 0; // tag 1

  @override
  void readFrom(TarsInputStream inputStream) {
    sFlvToken = inputStream.read(sFlvToken, 0, false);
    iExpireTime = inputStream.read(iExpireTime, 1, false);
  }

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(sFlvToken, 0);
    outputStream.write(iExpireTime, 1);
  }

  @override
  TarsStruct deepCopy() {
    return GetCdnTokenExResp()
      ..sFlvToken = sFlvToken
      ..iExpireTime = iExpireTime;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
