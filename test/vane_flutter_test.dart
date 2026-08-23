import 'dart:async';
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

  Map<String, Object?>? lastStreamingRequest;

  @override
  Future<VaneStreamingResponse> executeStreaming(
    int handle,
    Map<String, Object?> request,
  ) async {
    lastStreamingRequest = request;
    return VaneStreamingResponse(
      head: VaneResponse(
        statusCode: 200,
        headers: const <String, String>{'content-type': 'text/plain'},
        body: Uint8List(0),
        isSuccess: true,
        url: request['url'] as String,
      ),
      body: Stream<Uint8List>.fromIterable(<Uint8List>[
        Uint8List.fromList('str'.codeUnits),
        Uint8List.fromList('eam'.codeUnits),
      ]),
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

  final List<(int, String?)> warmupCalls = <(int, String?)>[];

  @override
  Future<void> warmup(int handle, String? url) async {
    warmupCalls.add((handle, url));
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

  test('warmup creates the client and forwards the target url', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient();
    await client.warmup();
    await client.warmup('https://api.example.com');

    // One native client, created by the warmup itself — that construction is
    // part of what warmup exists to pay early.
    expect(fakePlatform.createdClients, 1);
    expect(fakePlatform.warmupCalls, <(int, String?)>[
      (7, null),
      (7, 'https://api.example.com'),
    ]);

    VaneFlutterPlatform.instance = initialPlatform;
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

  test('configuration toMap carries the v5 knobs to the platform', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    // Defaults first, pinned to the numbers Rust's `Default` spells — the
    // two sides must not drift the way maxIdleConnections once did.
    await VaneClient().get('/defaults');
    expect(fakePlatform.lastConfiguration?['maxRedirects'], 10);
    expect(fakePlatform.lastConfiguration?['tlsMinVersion'], isNull);
    expect(fakePlatform.lastConfiguration?['tlsMaxVersion'], isNull);
    expect(fakePlatform.lastConfiguration?['customRootCertificates'], isEmpty);
    expect(fakePlatform.lastConfiguration?['clientCertificate'], isNull);

    final client = VaneClient(
      configuration: const VaneConfiguration(
        maxRedirects: 5,
        tlsMinVersion: VaneTlsVersion.tls12,
        tlsMaxVersion: VaneTlsVersion.tls13,
        customRootCertificates: <String>['root-pem'],
        clientCertificate: VaneClientCertificate(
          certificatePem: 'cert-pem',
          privateKeyPem: 'key-pem',
        ),
      ),
    );
    await client.get('/knobs');

    expect(fakePlatform.lastConfiguration?['maxRedirects'], 5);
    expect(fakePlatform.lastConfiguration?['tlsMinVersion'], 'tls12');
    expect(fakePlatform.lastConfiguration?['tlsMaxVersion'], 'tls13');
    expect(fakePlatform.lastConfiguration?['customRootCertificates'], <String>[
      'root-pem',
    ]);
    expect(
      fakePlatform.lastConfiguration?['clientCertificate'],
      <String, String>{
        'certificatePem': 'cert-pem',
        'privateKeyPem': 'key-pem',
      },
    );

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

  test('bodyStream rides the request map and displaces the other body '
      'sources', () async {
    final fakePlatform = MockVaneFlutterPlatform();
    VaneFlutterPlatform.instance = fakePlatform;

    final client = VaneClient();
    final source = Stream<Uint8List>.fromIterable(<Uint8List>[
      Uint8List.fromList(<int>[1, 2]),
    ]);
    await client
        .request('/upload', method: 'POST')
        .body(Uint8List.fromList(<int>[9]))
        .bodyStream(source, contentLength: 2)
        .execute();

    expect(fakePlatform.lastRequest?['bodyStream'], same(source));
    expect(fakePlatform.lastRequest?['bodyStreamContentLength'], 2);
    expect(fakePlatform.lastRequest?['body'], isNull);
    expect(fakePlatform.lastRequest?['bodyFilePath'], isNull);

    // And the reverse: a later buffered body displaces the stream, so a
    // request can never carry two body sources into the core's refusal.
    await client
        .request('/upload', method: 'POST')
        .bodyStream(source)
        .body(Uint8List.fromList(<int>[3]))
        .execute();

    expect(fakePlatform.lastRequest?['bodyStream'], isNull);
    expect(fakePlatform.lastRequest?['bodyStreamContentLength'], isNull);
    expect(fakePlatform.lastRequest?['body'], orderedEquals(<int>[3]));

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

  test(
    'executeStreaming runs request interceptors and registers the cancel '
    'token, but keeps response interceptors away from the stream',
    () async {
      final fakePlatform = MockVaneFlutterPlatform();
      var responseInterceptorRuns = 0;
      final client = VaneClient(platform: fakePlatform)
        ..addRequestInterceptor(
          (request) => request.copyWith(
            headers: <String, String>{...request.headers, 'x-shaped': '1'},
          ),
        )
        ..addResponseInterceptor((response) {
          responseInterceptorRuns += 1;
          return response;
        });

      final token = VaneCancelToken();
      final response = await client
          .request('https://example.com/stream')
          .cancelToken(token)
          .executeStreaming();

      expect(fakePlatform.lastStreamingRequest?['url'],
          'https://example.com/stream');
      expect(
        (fakePlatform.lastStreamingRequest?['headers']
            as Map<String, String>?)?['x-shaped'],
        '1',
        reason: 'request interceptors shape streaming requests too',
      );
      expect(fakePlatform.createdCancelTokens, 1);
      expect(fakePlatform.lastStreamingRequest?['cancelTokenId'], 11);

      expect(response.head.statusCode, 200);
      expect(response.head.body, isEmpty);
      final body = await response.body.toList();
      expect(String.fromCharCodes(body.expand((chunk) => chunk)), 'stream');
      expect(
        responseInterceptorRuns,
        0,
        reason: 'a buffered-response interceptor cannot rewrite a stream; '
            'the streaming path deliberately skips them',
      );

      await token.dispose();
      await client.close();
    },
  );

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
