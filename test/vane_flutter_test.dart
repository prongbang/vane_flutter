import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';
import 'package:vane_flutter/vane_flutter_method_channel.dart';
import 'package:vane_flutter/vane_flutter_platform_interface.dart';

class MockVaneFlutterPlatform
    with MockPlatformInterfaceMixin
    implements VaneFlutterPlatform {
  int createdClients = 0;
  Map<String, Object?>? lastConfiguration;
  Map<String, Object?>? lastRequest;
  final Map<String, List<String>> certificatePins = <String, List<String>>{};

  @override
  Future<int> createClient(Map<String, Object?> configuration) async {
    createdClients += 1;
    lastConfiguration = configuration;
    return 7;
  }

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    lastRequest = request;
    return VaneResponse(
      statusCode: 200,
      headers: const <String, String>{'content-type': 'text/plain'},
      body: Uint8List.fromList('ok'.codeUnits),
      isSuccess: true,
      url: request['url'] as String,
    );
  }

  @override
  Future<void> closeClient(int handle) async {}

  @override
  Future<void> setCertificatePins(
    int handle,
    String host,
    List<String> pins,
  ) async {
    if (pins.isEmpty) {
      certificatePins.remove(host);
    } else {
      certificatePins[host] = List<String>.of(pins);
    }
  }

  int createdCancelTokens = 0;
  final List<int> cancelledTokens = <int>[];
  final List<int> freedCancelTokens = <int>[];

  @override
  Future<int> createCancelToken() async {
    createdCancelTokens += 1;
    return 11;
  }

  @override
  Future<void> cancelToken(int id) async => cancelledTokens.add(id);

  @override
  Future<void> freeCancelToken(int id) async => freedCancelTokens.add(id);

  @override
  Future<int> createProgress() async => 13;

  @override
  Future<VaneProgress> progressSnapshot(int id) async {
    return const VaneProgress(
      uploadSent: 4,
      uploadTotal: 4,
      downloadReceived: 2,
      downloadTotal: 0,
      done: true,
    );
  }

  @override
  Future<void> freeProgress(int id) async {}
}

void main() {
  final initialPlatform = VaneFlutterPlatform.instance;

  test('$FfiVaneFlutter is the default instance', () {
    expect(initialPlatform, isInstanceOf<FfiVaneFlutter>());
  });

  test('$MethodChannelVaneFlutter remains available as a fallback', () {
    expect(MethodChannelVaneFlutter(), isA<MethodChannelVaneFlutter>());
  });

  test('client executes requests through the platform', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient(
      requestInterceptors: [
        (request) => request.copyWith(
          headers: <String, String>{...request.headers, 'x-test': '1'},
        ),
      ],
    );
    final response = await client
        .request('/users')
        .queryParam('page', '1')
        .execute();

    expect(response.text, 'ok');
    expect(fakePlatform.createdClients, 1);
    expect(fakePlatform.lastRequest?['url'], '/users');
    expect(fakePlatform.lastRequest?['queryParams'], <String, String>{
      'page': '1',
    });
    expect(fakePlatform.lastRequest?['headers'], <String, String>{
      'x-test': '1',
    });

    VaneFlutterPlatform.instance = initialPlatform;
  });

  test('direct client methods apply request options', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final token = VaneCancelToken();
    final client = VaneClient();
    await client.get(
      '/report',
      options: VaneRequestOptions(
        headers: const <String, String>{'accept': 'application/json'},
        queryParams: const <String, String>{'page': '2'},
        timeoutSeconds: 5,
        followRedirects: false,
        cancelToken: token,
        responseBodyPath: '/tmp/report.json',
      ),
    );

    expect(fakePlatform.lastRequest?['headers'], <String, String>{
      'accept': 'application/json',
    });
    expect(fakePlatform.lastRequest?['queryParams'], <String, String>{
      'page': '2',
    });
    expect(fakePlatform.lastRequest?['timeoutSeconds'], 5);
    expect(fakePlatform.lastRequest?['followRedirects'], false);
    expect(fakePlatform.lastRequest?['cancelTokenId'], 11);
    expect(fakePlatform.lastRequest?['responseBodyPath'], '/tmp/report.json');

    await token.dispose();
    VaneFlutterPlatform.instance = initialPlatform;
  });

  test(
    'client supports adding and clearing interceptors after creation',
    () async {
      final fakePlatform = MockVaneFlutterPlatform();
      VaneFlutterPlatform.instance = fakePlatform;

      final client = VaneClient()
        ..addRequestInterceptor(
          (request) => request.copyWith(
            headers: <String, String>{...request.headers, 'x-late': '1'},
          ),
        )
        ..addResponseInterceptor(
          (response) => VaneResponse(
            statusCode: response.statusCode,
            headers: <String, String>{...response.headers, 'x-response': '1'},
            body: response.body,
            bodyFilePath: response.bodyFilePath,
            isSuccess: response.isSuccess,
            url: response.url,
          ),
        );

      final response = await client.get('/late');

      expect(fakePlatform.lastRequest?['headers'], <String, String>{
        'x-late': '1',
      });
      expect(response.headers['x-response'], '1');

      client.clearInterceptors();
      await client.get('/clear');

      expect(fakePlatform.lastRequest?['headers'], isEmpty);
      VaneFlutterPlatform.instance = initialPlatform;
    },
  );

  test(
    'client updates certificate pins after native client creation',
    () async {
      final fakePlatform = MockVaneFlutterPlatform();
      VaneFlutterPlatform.instance = fakePlatform;

      final client = VaneClient();
      await client.setCertificatePins('api.example.com', <String>[
        'sha256/current',
        'sha256/backup',
      ]);

      expect(fakePlatform.createdClients, 1);
      expect(fakePlatform.certificatePins['api.example.com'], <String>[
        'sha256/current',
        'sha256/backup',
      ]);

      await client.clearCertificatePins('api.example.com');

      expect(fakePlatform.createdClients, 1);
      expect(fakePlatform.certificatePins, isNot(contains('api.example.com')));
      VaneFlutterPlatform.instance = initialPlatform;
    },
  );

  test(
    'upload and download helpers pass file paths without body allocation',
    () async {
      final fakePlatform = MockVaneFlutterPlatform();
      VaneFlutterPlatform.instance = fakePlatform;

      final client = VaneClient();
      await client.uploadFile('/upload', '/tmp/input.bin');

      expect(fakePlatform.lastRequest?['method'], 'POST');
      expect(fakePlatform.lastRequest?['bodyFilePath'], '/tmp/input.bin');
      expect(fakePlatform.lastRequest?['body'], isNull);

      await client.download('/download', '/tmp/output.bin');

      expect(fakePlatform.lastRequest?['method'], 'GET');
      expect(fakePlatform.lastRequest?['responseBodyPath'], '/tmp/output.bin');

      VaneFlutterPlatform.instance = initialPlatform;
    },
  );

  test('multipart supports explicit file metadata', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient();
    await client
        .request('/upload', method: 'POST')
        .multipart(
          fields: const <String, String>{'title': 'avatar'},
          fileParts: <VaneMultipartFile>[
            VaneMultipartFile(
              fieldName: 'photo',
              fileName: 'me.jpg',
              contentType: 'image/jpeg',
              bytes: Uint8List.fromList(<int>[1, 2, 3]),
            ),
          ],
        )
        .execute();

    final headers = fakePlatform.lastRequest?['headers'] as Map<String, String>;
    final body = String.fromCharCodes(
      fakePlatform.lastRequest?['body'] as Uint8List,
    );
    expect(
      headers['Content-Type'],
      startsWith('multipart/form-data; boundary='),
    );
    expect(body, contains('name="title"'));
    expect(body, contains('name="photo"; filename="me.jpg"'));
    expect(body, contains('Content-Type: image/jpeg'));

    VaneFlutterPlatform.instance = initialPlatform;
  });

  test('body and bodyFile helpers are mutually exclusive', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient();
    await client
        .request('/upload', method: 'POST')
        .bodyFile('/tmp/input.bin')
        .body(Uint8List.fromList(<int>[9]))
        .execute();

    expect(fakePlatform.lastRequest?['bodyFilePath'], isNull);
    expect(fakePlatform.lastRequest?['body'], orderedEquals(<int>[9]));

    await client
        .request('/upload', method: 'POST')
        .body(Uint8List.fromList(<int>[1]))
        .bodyFile('/tmp/input.bin')
        .execute();

    expect(fakePlatform.lastRequest?['bodyFilePath'], '/tmp/input.bin');
    expect(fakePlatform.lastRequest?['body'], isNull);

    VaneFlutterPlatform.instance = initialPlatform;
  });

  test('a cancel that lands before the token registers still reaches the '
      'core', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final token = VaneCancelToken();
    // The README's shape: cancel in the same microtask as the request, before
    // `execute` has had a chance to hand the token a native id. This used to
    // discard the intent outright and let the request run to completion.
    final pending = Vane.get(
      '/slow',
      options: VaneRequestOptions(cancelToken: token),
    );
    await token.cancel();
    await pending;

    expect(token.isCancelled, isTrue);
    expect(fakePlatform.createdCancelTokens, 1);
    expect(fakePlatform.cancelledTokens, <int>[11]);
    expect(fakePlatform.lastRequest?['cancelTokenId'], 11);

    await token.dispose();
    expect(fakePlatform.freedCancelTokens, <int>[11]);

    // `dispose` clears the latch as well as the native id. A controller that
    // holds one token as a field and disposes it in a `finally` — the README's
    // own shape — must be able to retry; leaving the latch armed made the
    // token cancel every later request forever, with no public way to reset.
    expect(token.isCancelled, isFalse);
    fakePlatform.cancelledTokens.clear();
    await Vane.get('/retry', options: VaneRequestOptions(cancelToken: token));
    expect(fakePlatform.cancelledTokens, isEmpty);
    await token.dispose();

    // A stray cancel on a disposed token reaches nothing: the native id is
    // gone, so there is no freed id to cancel through.
    await token.cancel();
    expect(fakePlatform.cancelledTokens, isEmpty);

    await Vane.close();
    VaneFlutterPlatform.instance = initialPlatform;
  });

  test('VaneResponse.fromMap reads the new keys and defaults without them', () {
    final full = VaneResponse.fromMap(<Object?, Object?>{
      'statusCode': 200,
      'headers': <Object?, Object?>{},
      'isSuccess': true,
      'url': 'https://example.com/',
      'setCookie': <Object?>['a=1', 'b=2'],
      'httpVersion': 'http2',
    });
    expect(full.setCookie, <String>['a=1', 'b=2']);
    expect(full.httpVersion, VaneHttpVersion.http2);

    // An older plugin sends neither key, and an unknown spelling is not a
    // crash.
    final bare = VaneResponse.fromMap(<Object?, Object?>{
      'statusCode': 200,
      'headers': <Object?, Object?>{},
      'isSuccess': true,
      'url': 'https://example.com/',
      'httpVersion': 'http9',
    });
    expect(bare.setCookie, isEmpty);
    expect(bare.httpVersion, isNull);
  });
}
