// Shared fake-Dio helper for music tests: every request is answered
// from [respond] (URL → {'status': int, 'body': String}) and never
// touches the network. All requested URLs are appended to [log].
// Not a test file itself (no *_test.dart suffix) — imported by tests.
import 'package:dio/dio.dart';

Dio buildFakeDio({
  required Map<String, dynamic> Function(String url) respond,
  required List<String> log,
}) {
  final dio = Dio();
  dio.options.validateStatus = (_) => true;
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        log.add(url);
        final r = respond(url);
        final status = r['status'] as int? ?? 200;
        final body = r['body'];
        handler.resolve(
          Response<String>(
            requestOptions: options,
            statusCode: status,
            data: body is String ? body : null,
            headers: Headers.fromMap(
              {'content-type': ['application/json']},
            ),
          ),
        );
      },
    ),
  );
  return dio;
}
