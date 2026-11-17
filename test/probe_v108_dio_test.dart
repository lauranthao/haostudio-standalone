// PROBE ONLY: raw Dio connectivity from Dart on this VM — print the
// actual exception, don't swallow it.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/network/http_client.dart';

void main() {
  test('PROBE raw Dio GET zddyr', () async {
    final dio = sharedDio();
    try {
      final res = await dio.get<dynamic>(
        'https://yy.zddyr.top/lx/api/?source=wy&songmid=66285&quality=320k',
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      // ignore: avoid_print
      print('PROBE dio status: ${res.statusCode}');
      // ignore: avoid_print
      print('PROBE dio data head: ${res.data.toString().substring(0, 120)}');
    } catch (e) {
      // ignore: avoid_print
      print('PROBE dio EXCEPTION type: ${e.runtimeType}');
      // ignore: avoid_print
      print('PROBE dio EXCEPTION: $e');
      if (e is DioException) {
        // ignore: avoid_print
        print('PROBE dio error type: ${e.type} message: ${e.message}');
        // ignore: avoid_print
        print('PROBE dio underlying: ${e.error}');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('PROBE raw HttpClient GET (no proxy config)', () async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
          Uri.parse('https://yy.zddyr.top/lx/api/?source=wy&songmid=66285&quality=320k'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print('PROBE httpclient status: ${res.statusCode}');
    } catch (e) {
      // ignore: avoid_print
      print('PROBE httpclient EXCEPTION: $e');
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('PROBE HttpClient with findProxyFromEnvironment', () async {
    final client = HttpClient();
    client.findProxy = HttpClient.findProxyFromEnvironment;
    try {
      final req = await client.getUrl(
          Uri.parse('https://yy.zddyr.top/lx/api/?source=wy&songmid=66285&quality=320k'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print('PROBE proxy-httpclient status: ${res.statusCode}');
    } catch (e) {
      // ignore: avoid_print
      print('PROBE proxy-httpclient EXCEPTION: $e');
    } finally {
      client.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
