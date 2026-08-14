import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_platform_interface.dart';

/// Records what the adapter hands to the platform and replays a canned
/// response, so the `package:http` contract can be checked without a network.
class _RecordingPlatform
    with MockPlatformInterfaceMixin
    implements VaneFlutterPlatform {
  Map<String, Object?>? lastRequest;
  int closedClients = 0;
  Object? failWith;

  /// Holds [execute] open so a test can act while a request is in flight.
  Completer<void>? gate;
  VaneResponse response = VaneResponse(
    statusCode: 201,
    headers: const <String, String>{
      'content-type': 'text/plain',
      'x-multi': 'a, b',
    },
    body: Uint8List.fromList(utf8.encode('hello')),
    isSuccess: true,
    url: 'https://example.com/thing',
  );

  @override
  Future<int> createClient(Map<String, Object?> configuration) async => 1;

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    lastRequest = request;
    await gate?.future;
    final error = failWith;
    if (error != null) {
      throw error;
    }
    return response;
  }

  @override
  Future<void> closeClient(int handle) async {
    closedClients += 1;
  }

  @override
  Future<VaneStreamingResponse> executeStreaming(
    int handle,
    Map<String, Object?> request,
  ) {
    // The package:http adapter buffers every response today; nothing routes
    // here.
    throw UnimplementedError('streaming is not used by the http adapter');
  }

  @override
  Future<void> setCertificatePins(
    int handle,
    String host,
    List<String> pins,
  ) async {}

  @override
  Future<void> warmup(int handle, String? url) async {}

  @override
  Future<int> createCancelToken() async => 1;

  @override
  Future<void> cancelToken(int id) async => cancelledTokens.add(id);
  final List<int> cancelledTokens = <int>[];

  @override
  Future<void> freeCancelToken(int id) async {}

  @override
  Future<int> createProgress() async => 1;

  @override
  Future<VaneProgress> progressSnapshot(int id) async => const VaneProgress(
    uploadSent: 0,
    uploadTotal: 0,
    downloadReceived: 0,
    downloadTotal: 0,
    done: true,
  );

  @override
  Future<void> freeProgress(int id) async {}
}

void main() {
  late _RecordingPlatform fake;
  late VaneClient vane;

  setUp(() {
    fake = _RecordingPlatform();
    vane = VaneClient(platform: fake);
  });

  test('get passes url, method and headers through to the core', () async {
    final client = VaneHttpClient(client: vane);
    final response = await client.get(
      Uri.parse('https://example.com/thing?page=1'),
      headers: <String, String>{'accept': 'text/plain'},
    );

    expect(fake.lastRequest?['url'], 'https://example.com/thing?page=1');
    expect(fake.lastRequest?['method'], 'GET');
    expect(
      (fake.lastRequest?['headers'] as Map<String, String>)['accept'],
      'text/plain',
    );
    expect(fake.lastRequest?['followRedirects'], true);
    expect(fake.lastRequest?['body'], isNull);

    expect(response.statusCode, 201);
    expect(response.body, 'hello');
    expect(response.headers['content-type'], 'text/plain');
    expect(response.headers['x-multi'], 'a, b');
    expect(response.contentLength, 5);
    // No set-cookie on this response, so no phantom key either.
    expect(response.headers, isNot(contains('set-cookie')));
  });

  test('set-cookie is comma-joined into the headers map', () async {
    fake.response = VaneResponse(
      statusCode: 200,
      headers: const <String, String>{'content-type': 'text/plain'},
      body: Uint8List(0),
      isSuccess: true,
      url: 'https://example.com/thing',
      // The first value carries an `Expires`, whose comma is what makes the
      // joined string unsplittable by a naive `split(',')`.
      setCookie: const <String>[
        'a=1; Expires=Wed, 09 Jun 2021 10:18:14 GMT',
        'b=2; Path=/',
      ],
    );
    final client = VaneHttpClient(client: vane);

    final response = await client.get(Uri.parse('https://example.com/thing'));

    // Lossy on purpose: BaseResponse.headers is Map<String, String> and this
    // is what package:http's own IOClient does. VaneResponse.setCookie is the
    // lossless path.
    expect(
      response.headers['set-cookie'],
      'a=1; Expires=Wed, 09 Jun 2021 10:18:14 GMT,b=2; Path=/',
    );
    // Recoverable, but only through package:http's own set-cookie splitter —
    // `split(',')` would yield three fragments and strip a=1's expiry.
    expect(response.headersSplitValues['set-cookie'], <String>[
      'a=1; Expires=Wed, 09 Jun 2021 10:18:14 GMT',
      'b=2; Path=/',
    ]);
  });

  test('post sends the finalized body and its content type', () async {
    final client = VaneHttpClient(client: vane);
    await client.post(
      Uri.parse('https://example.com/thing'),
      body: 'name=vane',
      headers: <String, String>{'content-type': 'text/plain'},
    );

    expect(fake.lastRequest?['method'], 'POST');
    expect(fake.lastRequest?['body'], utf8.encode('name=vane'));
    // http finalizes the charset onto the content type; the adapter forwards
    // the finalized headers verbatim rather than the ones passed in.
    expect(
      (fake.lastRequest?['headers'] as Map<String, String>)['content-type'],
      'text/plain; charset=utf-8',
    );
  });

  test('followRedirects on the http request reaches the core', () async {
    final client = VaneHttpClient(client: vane);
    final request = http.Request('GET', Uri.parse('https://example.com/thing'))
      ..followRedirects = false;
    await client.send(request);

    expect(fake.lastRequest?['followRedirects'], false);
  });

  test('core failures surface as ClientException', () async {
    fake.failWith = const VaneHttpException('Failed to resolve host');
    final client = VaneHttpClient(client: vane);

    await expectLater(
      client.get(Uri.parse('https://example.com/thing')),
      throwsA(
        isA<http.ClientException>()
            .having((e) => e.message, 'message', 'Failed to resolve host')
            .having(
              (e) => e.uri,
              'uri',
              Uri.parse('https://example.com/thing'),
            ),
      ),
    );
  });

  test('close is idempotent and rejects later requests', () async {
    final client = VaneHttpClient(client: vane);
    await client.get(Uri.parse('https://example.com/thing'));

    client
      ..close()
      ..close();

    await expectLater(
      client.get(Uri.parse('https://example.com/thing')),
      throwsA(isA<http.ClientException>()),
    );
  });

  test(
    'closing mid-send fails the request instead of reopening a client',
    () async {
      final client = VaneHttpClient(client: vane);
      final request = http.StreamedRequest(
        'POST',
        Uri.parse('https://example.com/thing'),
      );
      final pending = client.send(request);

      // send() is parked on finalize(); close lands in that window.
      await Future<void>.delayed(Duration.zero);
      client.close();
      request.sink.add(<int>[1]);
      await request.sink.close();

      await expectLater(pending, throwsA(isA<http.ClientException>()));
    },
  );

  test('a closed VaneClient refuses to reopen', () async {
    await vane.close();

    await expectLater(
      vane.get('https://example.com/thing'),
      throwsA(isA<StateError>()),
    );
  });

  test('an unparsable status becomes a ClientException', () async {
    fake.response = VaneResponse(
      statusCode: 0,
      headers: const <String, String>{},
      body: Uint8List(0),
      isSuccess: false,
      url: 'https://example.com/thing',
    );
    final client = VaneHttpClient(client: vane);

    await expectLater(
      client.get(Uri.parse('https://example.com/thing')),
      throwsA(
        isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          contains('Invalid status code 0'),
        ),
      ),
    );
  });

  test('an already-aborted request never reaches the core', () async {
    final client = VaneHttpClient(client: vane);
    final request = http.AbortableRequest(
      'GET',
      Uri.parse('https://example.com/thing'),
      abortTrigger: Future<void>.value(),
    );

    await expectLater(
      client.send(request),
      throwsA(isA<http.RequestAbortedException>()),
    );
    expect(fake.lastRequest, isNull);
  });


  test('aborting in flight surfaces as RequestAbortedException', () async {
    final gate = Completer<void>();
    final abort = Completer<void>();
    fake
      ..gate = gate
      ..failWith = const VaneHttpException('Vane request was cancelled');
    final client = VaneHttpClient(client: vane);

    final pending = client.send(
      http.AbortableRequest(
        'GET',
        Uri.parse('https://example.com/thing'),
        abortTrigger: abort.future,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    abort.complete();
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    await expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
    expect(fake.lastRequest?['cancelTokenId'], isNotNull);
    expect(fake.cancelledTokens, <int>[1]);
  });

  test(
    'an injected client outlives the adapter, an owned one does not',
    () async {
      final shared = VaneHttpClient(client: vane);
      await shared.get(Uri.parse('https://example.com/thing'));
      shared.close();
      await Future<void>.delayed(Duration.zero);
      expect(fake.closedClients, 0, reason: 'injected client must stay open');

      final previous = VaneFlutterPlatform.instance;
      addTearDown(() => VaneFlutterPlatform.instance = previous);
      VaneFlutterPlatform.instance = fake;
      final owned = VaneHttpClient();
      await owned.get(Uri.parse('https://example.com/thing'));
      owned.close();
      await Future<void>.delayed(Duration.zero);
      expect(fake.closedClients, 1, reason: 'owned client must be closed');

      await vane.close();
    },
  );
}
