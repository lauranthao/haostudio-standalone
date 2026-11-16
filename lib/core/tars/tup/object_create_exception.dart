// TUP attribute decode failure — port of Pure Live 3.x
// lib/core/tars/tup/object_create_exception.dart.

class ObjectCreateException implements Exception {
  ObjectCreateException(this.message);

  final String message;

  @override
  String toString() => 'ObjectCreateException: $message';
}
