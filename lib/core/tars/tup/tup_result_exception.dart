// Non-zero TUP result code — port of Pure Live 3.x
// lib/core/tars/tup/tup_result_exception.dart.

class TupResultException implements Exception {
  TupResultException(this.code, {this.message});

  final int code;
  final String? message;

  @override
  String toString() => '{code: $code, message: $message}';
}
