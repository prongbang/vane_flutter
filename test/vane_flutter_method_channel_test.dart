import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelVaneFlutter();
  const channel = MethodChannel('vane_flutter');
  final calls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          calls.add(methodCall);
          switch (methodCall.method) {
            case 'createClient':
              return 42;
            case 'execute':
              // The exact shape both native plugins' toMap() serializes:
              // ordered [name, value] pairs, duplicates preserved, set-cookie
              // inline, plus remoteIp. The parser and the plugins move
              // together — this fixture is the Dart end of that contract.
              return <String, Object?>{
                'statusCode': 200,
                'headers': <Object?>[
                  <Object?>['set-cookie', 'a=1'],
                  <Object?>['content-type', 'text/plain'],
                  <Object?>['set-cookie', 'b=2'],
                ],
                'body': Uint8List.fromList('ok'.codeUnits),
                'isSuccess': true,
                'url': 'https://example.com',
                'httpVersion': 'http3',
                'remoteIp': '203.0.113.7',
              };
            case 'closeClient':
              return null;
          }
          throw PlatformException(code: 'not-implemented');
        });
  });

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('createClient returns native handle', () async {
    expect(await platform.createClient(const <String, Object?>{}), 42);
    expect(calls.single.method, 'createClient');
  });

  test('execute decodes native response', () async {
    final response = await platform.execute(42, const <String, Object?>{
      'url': 'https://example.com',
      'method': 'GET',
    });

    expect(response.statusCode, 200);
    expect(response.text, 'ok');
    // The plugin-shaped map parses into the same model the FFI path
    // produces: the ordered pair list with both duplicates, the derived
    // views over it, and remoteIp.
    expect(response.headers, <(String, String)>[
      ('set-cookie', 'a=1'),
      ('content-type', 'text/plain'),
      ('set-cookie', 'b=2'),
    ]);
    expect(response.headerMap['content-type'], 'text/plain');
    expect(response.setCookie, <String>['a=1', 'b=2']);
    expect(response.httpVersion, VaneHttpVersion.http3);
    expect(response.remoteIp, '203.0.113.7');
    expect(calls.single.method, 'execute');
  });

  test('a streamed request body is refused before touching the channel',
      () async {
    await expectLater(
      platform.execute(42, <String, Object?>{
        'url': 'https://example.com',
        'method': 'POST',
        'bodyStream': Stream<Uint8List>.fromIterable(<Uint8List>[
          Uint8List.fromList('x'.codeUnits),
        ]),
      }),
      throwsUnsupportedError,
    );
    expect(calls, isEmpty,
        reason: 'the refusal must not leak an unsendable Stream into the '
            'codec');
  });
}
