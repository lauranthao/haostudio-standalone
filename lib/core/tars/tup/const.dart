// TUP packet-type constants — port of Pure Live 3.x
// lib/core/tars/tup/const.dart.
//
// Only the TUP3 constants are used: every Huya WUP call in this project
// (getCdnTokenInfoEx, getHeadLineMessageBoard) speaks TUP3.

abstract final class TupConst {
  static const int packetTypeTarsNormal = 0;
  static const int packetTypeTarsOneway = 1;
  static const int packetTypeTup = 2;
  static const int packetTypeTup3 = 3;
}
