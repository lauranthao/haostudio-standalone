// AndroidAbi detection tests (P1-A1).
//
// The native channel is faked: no Android, no DeviceInfoPlugin.
// Detection caches after the first call; anything unknown yields null
// so callers fall back to the fat APK.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/android_abi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(androidDeviceInfoChannelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AndroidAbi.resetForTest();
  });

  test('first ABI wins', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getSupportedAbis');
      return <String>['arm64-v8a', 'armeabi-v7a'];
    });
    expect(await AndroidAbi.detect(), 'arm64-v8a');
    expect(AndroidAbi.current, 'arm64-v8a');
  });

  test('detect caches: the channel is called once', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return <String>['x86_64'];
    });
    expect(await AndroidAbi.detect(), 'x86_64');
    expect(await AndroidAbi.detect(), 'x86_64');
    expect(calls, 1);
  });

  test('empty list -> null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => <String>[]);
    expect(await AndroidAbi.detect(), isNull);
    expect(AndroidAbi.current, isNull);
  });

  test('missing channel -> null, never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no native side');
    });
    expect(await AndroidAbi.detect(), isNull);
    expect(AndroidAbi.current, isNull);
  });

  test('setTestAbi overrides for other tests', () {
    AndroidAbi.setTestAbi('armeabi-v7a');
    expect(AndroidAbi.current, 'armeabi-v7a');
    AndroidAbi.setTestAbi(null);
    expect(AndroidAbi.current, isNull);
  });
}
