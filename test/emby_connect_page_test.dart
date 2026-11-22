// Emby connect page — widget tests (build 29, C group).
//
// Pumps the real page with a canned client (zero network) and a
// Hive test box, so "连接并保存" really writes the config.
// Fixture credentials are FAKE, never real.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/features/settings/emby_connect_page.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

EmbyResponse okJson(dynamic json) =>
    EmbyResponse(statusCode: 200, json: json);

Future<EmbyResponse> cannedFetcher(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  if (url.contains('/System/Info/Public')) {
    return okJson({'ServerName': 'Home', 'Version': '4.8.0'});
  }
  if (url.contains('/System/Info')) {
    return okJson({'ServerName': 'Home', 'Version': '4.8.0'});
  }
  if (url.contains('/Users')) {
    return okJson({
      'Items': [
        {'Id': 'user-1', 'Name': 'chen'},
      ],
    });
  }
  return const EmbyResponse(statusCode: 404, json: {});
}

Future<EmbyResponse> cannedMutator(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? jsonBody,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  if (url.contains('/Users/AuthenticateByName')) {
    if ((jsonBody?['Pw'] as String?) == 'wrong-fake') {
      return const EmbyResponse(statusCode: 401, json: {});
    }
    return okJson({
      'AccessToken': 'tok-fake-abc',
      'User': {'Id': 'user-9', 'Name': 'chen'},
    });
  }
  return okJson({});
}

EmbyClient cannedClient(EmbyServerConfig config) => EmbyClient(
      config: config,
      fetcher: cannedFetcher,
      mutator: cannedMutator,
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-emby-connect-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_emby_connect',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    Get.put(ThemeController());
    HiveStore.box.delete(HiveKeys.embyConfig);
  });

  tearDown(() {
    Get.reset();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    EmbyServerConfig? initialConfig,
    EmbyClient Function(EmbyServerConfig config)? clientFactory,
  }) async {
    // Tall viewport: the page is one ListView and off-screen rows
    // are not built at the default 800x600 test size.
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: EmbyConnectPage(
          initialConfig: initialConfig,
          clientFactory: clientFactory ?? cannedClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool connectEnabled(WidgetTester tester) {
    final button =
        tester.widget<FilledButton>(find.byType(FilledButton));
    return button.onPressed != null;
  }

  Future<void> fill(
    WidgetTester tester,
    String key,
    String value,
  ) async {
    await tester.enterText(find.byKey(Key(key)), value);
    await tester.pump();
  }

  testWidgets('empty: button disabled, no Trakt row, groups present',
      (tester) async {
    await pumpPage(tester);
    expect(find.text('添加 Emby'), findsOneWidget);
    expect(find.text('媒体库、元数据与播放进度'), findsOneWidget);
    for (final label in ['名称', '备注', '地址', '端口', '路径', '用户名', '密码']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('HTTPS'), findsOneWidget);
    expect(find.text('备用线路'), findsOneWidget);
    expect(find.text('未播放提醒'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);
    // Collapsed: no advanced rows yet.
    expect(find.text('数据上报'), findsNothing);
    expect(find.text('STRM 直连'), findsNothing);
    // Trakt is deliberately not on the page (no login interface).
    expect(find.textContaining('Trakt'), findsNothing);
    expect(connectEnabled(tester), isFalse);
  });

  testWidgets('host + username enables the button; host alone does not',
      (tester) async {
    await pumpPage(tester);
    await fill(tester, 'emby_host', 'server-fake.local');
    expect(connectEnabled(tester), isFalse);
    await fill(tester, 'emby_username', 'chen');
    expect(connectEnabled(tester), isTrue);
  });

  testWidgets('host + api key (no username) also enables the button',
      (tester) async {
    await pumpPage(tester);
    await fill(tester, 'emby_host', 'server-fake.local');
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await fill(tester, 'emby_api_key', 'key-fake-123');
    expect(connectEnabled(tester), isTrue);
  });

  testWidgets('password eye toggles visibility', (tester) async {
    await pumpPage(tester);
    TextField field() =>
        tester.widget<TextField>(find.byKey(const Key('emby_password')));
    expect(field().obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(field().obscureText, isFalse);
  });

  testWidgets('advanced expands: report + strm + api key, native switches',
      (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('数据上报'), findsOneWidget);
    expect(find.text('向服务器同步播放进度，用于继续观看和已看标记'),
        findsOneWidget);
    expect(find.text('STRM 直连'), findsOneWidget);
    expect(find.text('API 密钥'), findsOneWidget);
    // Switches are HaoNativeSwitch (Cupertino fallback in tests).
    expect(find.byType(CupertinoSwitch), findsNWidgets(3));
  });

  testWidgets('reminder picker stores the chosen days', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('未播放提醒'));
    await tester.pumpAndSettle();
    expect(find.text('7 天'), findsOneWidget);
    expect(find.text('30 天'), findsOneWidget);
    await tester.tap(find.text('7 天'));
    await tester.pumpAndSettle();
    expect(find.text('7 天'), findsOneWidget);
  });

  testWidgets('account login saves token + user id and pops true',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => EmbyConnectPage(
                    clientFactory: cannedClient,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await fill(tester, 'emby_host', 'server-fake.local');
    await fill(tester, 'emby_username', 'chen');
    await fill(tester, 'emby_password', 'pw-fake');
    // HTTPS on: skips the plain-http warning dialog.
    await tester.tap(find.byType(CupertinoSwitch).first);
    await tester.pump();
    await tester.tap(find.text('连接并保存'));
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    final saved = EmbyConfigStore.load();
    expect(saved, isNotNull);
    expect(saved!.accessToken, 'tok-fake-abc');
    expect(saved.userId, 'user-9');
    expect(saved.username, 'chen');
    expect(saved.baseUrl, 'https://server-fake.local:8096');
    expect(saved.serverName, 'Home');
    expect(saved.apiKey, '');
  });

  testWidgets('wrong password shows the account error and stays',
      (tester) async {
    await pumpPage(tester);
    await fill(tester, 'emby_host', 'server-fake.local');
    await fill(tester, 'emby_username', 'chen');
    await fill(tester, 'emby_password', 'wrong-fake');
    await tester.tap(find.byType(CupertinoSwitch).first);
    await tester.pump();
    await tester.tap(find.text('连接并保存'));
    await tester.pumpAndSettle();
    expect(find.text('Emby 用户名或密码不对，请重新登录'), findsOneWidget);
    expect(EmbyConfigStore.load(), isNull);
  });

  testWidgets('key mode saves with the probed single user',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => EmbyConnectPage(
                    clientFactory: cannedClient,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await fill(tester, 'emby_host', 'server-fake.local');
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    await fill(tester, 'emby_api_key', 'key-fake-123');
    await tester.tap(find.text('连接并保存'));
    await tester.pumpAndSettle();
    // Plain-http warning: confirm to proceed.
    expect(find.text('该地址使用明文 http'), findsOneWidget);
    await tester.tap(find.text('仍要连接'));
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    final saved = EmbyConfigStore.load();
    expect(saved, isNotNull);
    expect(saved!.apiKey, 'key-fake-123');
    expect(saved.accessToken, '');
    expect(saved.userId, 'user-1');
    expect(saved.baseUrl, 'http://server-fake.local:8096');
  });

  testWidgets('legacy config prefills split fields; edit keeps the token',
      (tester) async {
    const legacy = EmbyServerConfig(
      baseUrl: 'http://192.168.1.10:8096/emby',
      apiKey: 'key-fake-123',
      userId: 'user-1',
      username: 'chen',
      accessToken: 'tok-fake-abc',
      serverName: 'Home',
    );
    await pumpPage(tester, initialConfig: legacy);
    expect(find.text('编辑 Emby'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('emby_host')))
          .controller
          ?.text,
      '192.168.1.10',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('emby_path')))
          .controller
          ?.text,
      '/emby',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('emby_username')))
          .controller
          ?.text,
      'chen',
    );
    // Blank password + same username + saved token: re-probe keeps
    // the token instead of re-authing with an empty password.
    await tester.tap(find.byType(CupertinoSwitch).first);
    await tester.pump();
    await tester.tap(find.text('连接并保存'));
    await tester.pumpAndSettle();
    final saved = EmbyConfigStore.load();
    expect(saved, isNotNull);
    expect(saved!.accessToken, 'tok-fake-abc');
    expect(saved.userId, 'user-1');
  });

  testWidgets('fallback editor: add, test, delete, back with the list',
      (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('备用线路'));
    await tester.pumpAndSettle();
    expect(find.text('备用线路'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('emby_fallback_new')),
      'http://backup-fake:8096',
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('http://backup-fake:8096'), findsOneWidget);
    await tester.tap(find.text('测'));
    await tester.pumpAndSettle();
    expect(find.text('是 Emby 服务器'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('1 条备用地址'), findsOneWidget);
  });

  testWidgets('paste fills host/port/path/https from the clipboard',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{
          'text': 'https://emby-fake.example.com:8096/emby',
        };
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await pumpPage(tester);
    await tester.tap(find.byIcon(Icons.content_paste));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('emby_host')))
          .controller
          ?.text,
      'emby-fake.example.com',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('emby_path')))
          .controller
          ?.text,
      '/emby',
    );
    expect(find.text('HTTPS 连接'), findsOneWidget);
  });
}
