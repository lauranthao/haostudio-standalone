// TUP response envelope — port of Pure Live 3.x
// lib/core/tars/tup/tup_response.dart.

class TupResponse<T> {
  TupResponse({this.code = 0, this.response});

  int code;
  T? response;
}
