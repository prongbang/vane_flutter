import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http_profile/http_profile.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';

/// The Rust cdylib only exists after a local `cargo build` in `vane-rs`, so
/// these tests skip when it is missing (checkouts without a Rust toolchain).
/// `.invalid` hosts never resolve (RFC 2606), so every request fails in Rust
/// with the host echoed back — which is what proves the Dart-side strings
/// reached the native struct intact.
String? _libraryPath() {
  final override = Platform.environment['VANE_TEST_LIBRARY'];
  if (override != null) {
    return File(override).existsSync() ? override : null;
  }
  final extension = Platform.isMacOS ? 'dylib' : 'so';
  for (final candidate in <String>[
    '../vane-rs/target/release/libvane.$extension',
    '../vane-rs/target/release/deps/libvane.$extension',
    '../vane-rs/target/debug/libvane.$extension',
    '../vane-rs/target/debug/deps/libvane.$extension',
  ]) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

/// Same gate as the Rust live tests: an https:// origin that speaks HTTP/3.
String? _liveBaseUrl() {
  final base = Platform.environment['VANE_TEST_BASE_URL'];
  if (base == null || !base.startsWith('https://')) {
    return null;
  }
  return base;
}

/// Test-side mirror of the C ABI's `VaneFfiBuffer`, for probing the body
/// stream registry directly (the plugin's own struct is private).
final class _ProbeBuffer extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;

  @Size()
  external int cap;
}

Matcher _failsWithHost(String host) {
  return throwsA(
    isA<VaneHttpException>().having(
      (e) => e.message,
      'message',
      contains(host),
    ),
  );
}

/// The error kind rides in what used to be padding inside `VaneFfiResponse`, so
/// a wrong offset on either side of the boundary reads garbage rather than
/// failing to compile. Asserting a known kind against the real library is the
/// only thing that catches that.
Matcher _failsWithKind(VaneErrorKind kind) {
  return throwsA(isA<VaneHttpException>().having((e) => e.kind, 'kind', kind));
}

void main() {
  final libraryPath = _libraryPath();

  // Declared (and therefore run) before anything dlopens the real libvane:
  // on macOS a dlopen can make its symbols globally visible, which would let
  // `DynamicLibrary.process()` find `vane_ffi_abi_version` and invalidate the
  // missing-symbol case below.
  group('native ABI guard', () {
    test('a library without the version symbol is refused as skew', () async {
      // The test VM itself: a real library with no vane symbols in it — the
      // shape of a core that predates ABI versioning.
      final platform = FfiVaneFlutter(library: DynamicLibrary.process());
      await expectLater(
        platform.createClient(<String, Object?>{}),
        throwsA(
          isA<VaneHttpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('vane_ffi_abi_version'), contains('ABI v4')),
          ),
        ),
      );
    });
  });

  group(
    'FFI worker isolate',
    skip: libraryPath == null ? 'libvane is not built' : null,
    () {
      late FfiVaneFlutter platform;
      late int client;

      setUpAll(() async {
        platform = FfiVaneFlutter(library: DynamicLibrary.open(libraryPath!));
        client = await platform.createClient(<String, Object?>{
          'timeoutSeconds': 2,
        });
      });

      tearDownAll(() async {
        await platform.closeClient(client);
        platform.dispose();
      });

      /// Every failure path below must *fail*, not hang: a wedged worker shows
      /// up as a future that never completes, so each one is time-boxed.
      Future<void> expectFastFailure(Future<Object?> call, Matcher matcher) {
        return expectLater(call.timeout(const Duration(seconds: 10)), matcher);
      }

      /// The happy path of the guard is the whole group: setUpAll resolved
      /// the library through [verifyNativeAbi], so every test here already
      /// proves an injected, matching library passes. This pins the mismatch
      /// branch against the real symbol, naming both versions — and
      /// `expected: 3` is not an arbitrary wrong number: it is exactly the
      /// pairing the v4 struct growth creates (a v3-era plugin loading this
      /// library), the skew that would misread `VaneFfiRequest` past its end
      /// if the guard ever stopped firing.
      test('an ABI version mismatch is refused, naming both versions', () {
        final library = DynamicLibrary.open(libraryPath!);
        expect(verifyNativeAbi(library), same(library));
        expect(
          () => verifyNativeAbi(library, expected: 3),
          throwsA(
            isA<VaneHttpException>().having(
              (e) => e.message,
              'message',
              allOf(contains('ABI v4'), contains('v3')),
            ),
          ),
        );
      });

      test('propagates Rust errors with the request marshalled intact', () {
        expect(
          platform.execute(client, <String, Object?>{
            'url': 'https://vane-request-marker.invalid/probe',
            'method': 'GET',
          }),
          _failsWithHost('vane-request-marker.invalid'),
        );
      });

      test('multiplexes concurrent requests across the worker pool', () async {
        // More requests than the pool cap, so this covers both a growing pool
        // and requests queueing on an already busy worker.
        const hosts = <String>[
          'alpha',
          'beta',
          'gamma',
          'delta',
          'epsilon',
          'zeta',
        ];
        final messages = await Future.wait(
          hosts.map((host) async {
            try {
              await platform.execute(client, <String, Object?>{
                'url': 'https://vane-$host.invalid/probe',
                'method': 'GET',
              });
              return '';
            } on VaneHttpException catch (error) {
              return error.message;
            }
          }),
        );

        for (var index = 0; index < hosts.length; index += 1) {
          expect(messages[index], contains('vane-${hosts[index]}.invalid'));
        }
      });

      test('the error kind crosses the FFI boundary', () async {
        // A URL the core rejects outright, and a host that can never resolve:
        // two different kinds, so a constant would not pass.
        await expectLater(
          platform.execute(client, <String, Object?>{
            'url': 'http://[',
            'method': 'GET',
          }),
          _failsWithKind(VaneErrorKind.invalidRequest),
        );
        await expectLater(
          platform.execute(client, <String, Object?>{
            'url': 'https://vane-kind.invalid/probe',
            'method': 'GET',
          }),
          _failsWithKind(VaneErrorKind.transport),
        );
      });

      test('reuses the pool for a second client and its config', () async {
        final based = await platform.createClient(<String, Object?>{
          'baseUrl': 'https://vane-config-marker.invalid',
          'timeoutSeconds': 2,
        });

        await expectLater(
          platform.execute(based, <String, Object?>{
            'url': '/probe',
            'method': 'GET',
          }),
          _failsWithHost('vane-config-marker.invalid'),
        );

        await platform.closeClient(based);
      });

      test('warmup is best-effort and never throws across the FFI', () async {
        // Unresolvable host: the native side swallows the failure by
        // contract, so these completing at all is the assertion — of the
        // symbol, the struct marshalling, and the one-shot isolate hop.
        await platform
            .warmup(client, 'https://vane-warmup.invalid/probe')
            .timeout(const Duration(seconds: 10));
        // Null url falls back to the (unset) baseUrl.
        await platform.warmup(client, null).timeout(const Duration(seconds: 10));
        // An unknown handle warms nothing and still returns.
        await platform.warmup(999999, null).timeout(const Duration(seconds: 10));
      });

      test(
        'cancel token and progress calls stay on the main isolate',
        () async {
          final token = await platform.createCancelToken();
          await platform.cancelToken(token);
          await platform.freeCancelToken(token);

          final progress = await platform.createProgress();
          final snapshot = await platform.progressSnapshot(progress);
          await platform.freeProgress(progress);

          expect(token, greaterThan(0));
          expect(progress, greaterThan(0));
          expect(snapshot.done, isFalse);
          expect(snapshot.downloadReceived, 0);
        },
      );

      test(
        'an unsendable request fails fast and leaves the pool usable',
        () async {
          final port = ReceivePort();
          try {
            // A ReceivePort cannot cross isolates, so the send itself throws.
            await expectFastFailure(
              platform.execute(client, <String, Object?>{
                'url': 'https://vane-unsendable.invalid/probe',
                'method': 'GET',
                'unsendable': port,
              }),
              throwsA(isA<ArgumentError>()),
            );
          } finally {
            port.close();
          }

          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-after-unsendable.invalid/probe',
              'method': 'GET',
            }),
            _failsWithHost('vane-after-unsendable.invalid'),
          );
        },
      );

      test(
        'a request the worker cannot marshal fails fast, worker survives',
        () async {
          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-bad-body.invalid/probe',
              'method': 'GET',
              'body': 'not-bytes',
            }),
            throwsA(
              isA<VaneHttpException>().having(
                (e) => e.message,
                'message',
                contains('Uint8List'),
              ),
            ),
          );

          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-after-bad-body.invalid/probe',
              'method': 'GET',
            }),
            _failsWithHost('vane-after-bad-body.invalid'),
          );
        },
      );

      test(
        'dispose releases the workers and a later request respawns',
        () async {
          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-before-dispose.invalid/probe',
              'method': 'GET',
            }),
            _failsWithHost('vane-before-dispose.invalid'),
          );

          platform.dispose();
          platform.dispose(); // idempotent

          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-after-dispose.invalid/probe',
              'method': 'GET',
            }),
            _failsWithHost('vane-after-dispose.invalid'),
          );
        },
      );

      // Closest reachable proxy for a worker dying mid-request: it runs the
      // same "worker is gone" fan-out that onExit/onError trigger.
      test('losing a worker mid-request fails it instead of hanging', () async {
        final inFlight = platform.execute(client, <String, Object?>{
          'url': 'https://vane-inflight.invalid/probe',
          'method': 'GET',
        });
        // Let the request reach the worker before pulling it out from under it.
        await Future<void>.delayed(Duration.zero);
        platform.dispose();

        await expectFastFailure(inFlight, throwsA(isA<VaneHttpException>()));

        await expectFastFailure(
          platform.execute(client, <String, Object?>{
            'url': 'https://vane-after-inflight.invalid/probe',
            'method': 'GET',
          }),
          _failsWithHost('vane-after-inflight.invalid'),
        );
      });

      test(
        'a streaming request that fails before headers throws, marshalled '
        'intact, and leaks nothing',
        () async {
          // Exercises the whole pump path hermetically: spawn, the blocking
          // header call through vane_ffi_execute_streaming, the error head
          // decode, the internally-owned cancel token's release, and the
          // pump's self-exit. The echoed host proves the request crossed the
          // new symbol's marshalling.
          await expectFastFailure(
            platform.executeStreaming(client, <String, Object?>{
              'url': 'https://vane-streaming-marker.invalid/probe',
              'method': 'GET',
            }),
            _failsWithHost('vane-streaming-marker.invalid'),
          );

          // The failure classifies like the buffered path's.
          await expectFastFailure(
            platform.executeStreaming(client, <String, Object?>{
              'url': 'https://vane-streaming-kind.invalid/probe',
              'method': 'GET',
            }),
            _failsWithKind(VaneErrorKind.transport),
          );
        },
      );

      test(
        'a streaming request refuses responseBodyPath through the real ABI',
        () async {
          // Refused by the core before any network is touched, so this is
          // hermetic — and it proves an InvalidRequest error head round-trips
          // the new symbol with its kind intact.
          await expectFastFailure(
            platform.executeStreaming(client, <String, Object?>{
              'url': 'https://vane-streaming-path.invalid/probe',
              'method': 'GET',
              'responseBodyPath': '/tmp/vane-streaming-refused',
            }),
            _failsWithKind(VaneErrorKind.invalidRequest),
          );
        },
      );

      test(
        'a streamed upload whose request fails is released, cleaned up, and '
        'reports the request error',
        () async {
          // Exercises the whole upload chain hermetically against the real
          // core: create through the new symbol, the id crossing the grown
          // VaneFfiRequest, the writer isolate's blocking write, the core's
          // release latch failing the writer when the request dies at DNS,
          // and the driver's teardown. The echoed host proves the marshalled
          // request carried the stream id (the core resolved it — an unknown
          // id would fail with a different message before any connection).
          final controller = StreamController<Uint8List>();
          controller.add(Uint8List.fromList(List<int>.filled(1024, 7)));
          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-upload-marker.invalid/probe',
              'method': 'POST',
              'bodyStream': controller.stream,
            }),
            _failsWithHost('vane-upload-marker.invalid'),
          );
          await controller.close();
        },
      );

      test(
        'a source stream error aborts the upload and outranks the induced '
        'Cancelled',
        () async {
          // The .invalid DNS failure usually loses this race, so give the
          // request a moment of life: the source errors immediately, the
          // driver frees the native stream, the core aborts, and whatever
          // order the race resolves in, the caller must see the source's own
          // error — never the synthetic Cancelled it induced.
          final failure = StateError('the app source blew up');
          await expectFastFailure(
            platform.execute(client, <String, Object?>{
              'url': 'https://vane-upload-source-error.invalid/probe',
              'method': 'POST',
              'bodyStream': Stream<Uint8List>.error(failure),
            }),
            throwsA(
              anyOf(
                same(failure),
                // The DNS failure can genuinely win the race; what must
                // never surface is the abort-induced Cancelled.
                isA<VaneHttpException>().having(
                  (e) => e.kind,
                  'kind',
                  isNot(VaneErrorKind.cancelled),
                ),
              ),
            ),
          );
        },
      );

      test('the http adapter maps a real transport failure', () async {
        final vane = VaneClient(
          configuration: const VaneConfiguration(timeoutSeconds: 5),
          platform: platform,
        );
        final adapter = VaneHttpClient(client: vane);

        await expectFastFailure(
          adapter.get(Uri.parse('https://vane-adapter.invalid/probe')),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains('vane-adapter.invalid'),
            ),
          ),
        );

        adapter.close();
        await vane.close();
      });

      test('profiling is off by default, and off means no profile at all', () {
        // This is the exact gate the FFI layer checks before it allocates
        // anything, so "disabled costs a bool read" rests on it.
        expect(HttpClientRequestProfile.profilingEnabled, isFalse);
        expect(
          HttpClientRequestProfile.profile(
            requestStartTime: DateTime.now(),
            requestMethod: 'GET',
            requestUri: 'https://example.com/',
          ),
          isNull,
        );
      });

      test('recording a failed request changes nothing about it', () async {
        HttpClientRequestProfile.profilingEnabled = true;
        addTearDown(() => HttpClientRequestProfile.profilingEnabled = false);
        expect(
          HttpClientRequestProfile.profile(
            requestStartTime: DateTime.now(),
            requestMethod: 'GET',
            requestUri: 'https://example.com/',
          ),
          isNotNull,
          reason: 'profiling must actually be on for this to mean anything',
        );

        // Same error, same speed: the error branch records through
        // closeWithError and rethrows untouched.
        await expectFastFailure(
          platform.execute(client, <String, Object?>{
            'url': 'https://vane-profiled.invalid/probe',
            'method': 'GET',
            'headers': <String, String>{'x-probe': '1'},
            'body': Uint8List.fromList(<int>[1, 2, 3]),
          }),
          _failsWithHost('vane-profiled.invalid'),
        );

        // A URL Dart's Uri cannot parse must still fail as a Vane error:
        // profiling describes a request, it never gets to break one.
        await expectFastFailure(
          platform.execute(client, <String, Object?>{
            'url': 'http://[',
            'method': 'GET',
          }),
          throwsA(
            isA<VaneHttpException>().having(
              (e) => e.message,
              'message',
              contains('Invalid URL'),
            ),
          ),
        );

        // Same for a request map the recorder itself chokes on: the caller must
        // still get the ordinary Vane error, not the recorder's TypeError.
        await expectFastFailure(
          platform.execute(client, <String, Object?>{
            'url': 'https://vane-profiled-bad-body.invalid/probe',
            'method': 'GET',
            'body': 'not-bytes',
          }),
          throwsA(
            isA<VaneHttpException>().having(
              (e) => e.message,
              'message',
              contains('Uint8List'),
            ),
          ),
        );
      });

      test('the profile url mirrors the join the core performs', () {
        expect(
          profileRequestUri(<String, Object?>{
            'url': 'https://example.com/a',
          }, 'https://base.example/api/'),
          'https://example.com/a',
          reason: 'an absolute url wins over the base url',
        );
        expect(
          profileRequestUri(<String, Object?>{
            'url': 'users',
          }, 'https://base.example/api/'),
          'https://base.example/api/users',
        );
        expect(
          profileRequestUri(<String, Object?>{
            'url': 'https://example.com/a?keep=1',
            'queryParams': <String, String>{'page': '2'},
          }, null),
          'https://example.com/a?keep=1&page=2',
        );
      });

      // The zero-copy body only exists on a successful response, which needs a
      // real HTTP/3 server — same gate the Rust live tests use.
      test(
        'body stays valid as a view over the native buffer',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          final live = await platform.createClient(<String, Object?>{
            'timeoutSeconds': 20,
          });
          final response = await platform.execute(live, <String, Object?>{
            'url': _liveBaseUrl(),
            'method': 'GET',
          });

          expect(response.body, isNotEmpty);
          final contentLength = response.headers['content-length'];
          if (contentLength != null) {
            expect(response.body.length, int.parse(contentLength));
          }
          final snapshot = Uint8List.fromList(response.body);

          // Churn the native allocator and the Dart heap while holding the
          // view: a premature free would show up as changed bytes or a crash.
          for (var index = 0; index < 3; index += 1) {
            try {
              await platform.execute(live, <String, Object?>{
                'url': 'https://vane-churn-$index.invalid/probe',
                'method': 'GET',
              });
            } on VaneHttpException {
              // Expected — this is only here to allocate and free natively.
            }
          }
          expect(List<int>.generate(1 << 20, (i) => i & 0xff).length, 1 << 20);

          expect(response.body.length, snapshot.length);
          expect(Object.hashAll(response.body), Object.hashAll(snapshot));
          expect(response.text, isNotEmpty);

          await platform.closeClient(live);
        },
      );

      // The only thing that catches a struct-layout desync between Rust's
      // VaneFfiResponse and the Dart mirror: both new fields are decoded from
      // the real native response, not from a fake.
      test(
        'set-cookie and the negotiated protocol survive the real ABI',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 20,
          });
          final response = await platform.execute(live, <String, Object?>{
            'url': '/cookies/set/vane_cookie/1',
            'method': 'GET',
            'followRedirects': false,
          });

          expect(response.setCookie, isNotEmpty);
          expect(response.setCookie.first, contains('vane_cookie'));
          // Never in the map, or repeats would collapse silently.
          expect(response.headers, isNot(contains('set-cookie')));
          expect(response.httpVersion, VaneHttpVersion.http3);

          await platform.closeClient(live);
        },
      );

      test(
        'the http adapter round-trips a real response',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          final vane = VaneClient(
            configuration: const VaneConfiguration(timeoutSeconds: 20),
            platform: platform,
          );
          final adapter = VaneHttpClient(client: vane);

          final response = await adapter.get(Uri.parse(_liveBaseUrl()!));

          expect(response.statusCode, 200);
          expect(response.bodyBytes, isNotEmpty);
          expect(response.body, isNotEmpty);
          expect(response.headers, isNotEmpty);
          expect(response.request?.method, 'GET');

          adapter.close();
          await vane.close();
        },
      );

      test(
        'a profiled live request keeps its body and resolves its base url',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          HttpClientRequestProfile.profilingEnabled = true;
          addTearDown(() => HttpClientRequestProfile.profilingEnabled = false);

          // Relative url + baseUrl also drives the profile's URL join, and the
          // response body is handed to the profile sink while staying a
          // zero-copy view here.
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 20,
          });
          final response = await platform.execute(live, <String, Object?>{
            'url': '/',
            'method': 'GET',
          });

          expect(response.statusCode, 200);
          expect(response.body, isNotEmpty);
          expect(response.text, isNotEmpty);

          await platform.closeClient(live);
        },
      );

      test(
        'a live streamed body arrives whole, and survives a mid-stream pause',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          // /drip paces its writes across the duration (one write per byte),
          // so the body is guaranteed to still be in flight when the pause
          // lands — but numbytes must stay tiny, because the server really
          // does write byte by byte. (/bytes/N is no good here: httpbin caps
          // it at 100 KB and a fast origin delivers that faster than the
          // pause can land.)
          const totalBytes = 48;
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 30,
          });
          final response = await platform
              .executeStreaming(live, <String, Object?>{
                'url': '/drip',
                'method': 'GET',
                'queryParams': <String, String>{
                  'duration': '4',
                  'numbytes': '$totalBytes',
                },
              });

          expect(response.head.statusCode, 200);
          expect(response.head.body, isEmpty,
              reason: 'the head carries no body by contract');
          expect(response.head.httpVersion, VaneHttpVersion.http3);

          final received = BytesBuilder(copy: false);
          var paused = false;
          await for (final chunk in response.body) {
            received.add(chunk);
            if (!paused && received.length > totalBytes ~/ 4) {
              paused = true;
              // await-for keeps the subscription paused across this await:
              // one second of no demand mid-body. The transfer completing
              // afterwards is what proves a stalled consumer stalls the
              // transport instead of erroring or dropping data.
              await Future<void>.delayed(const Duration(seconds: 1));
            }
          }
          expect(received.length, totalBytes);
          expect(paused, isTrue,
              reason: 'the pause must land while the body is in flight');

          await platform.closeClient(live);
        },
      );

      test(
        'cancelling a live streamed body completes promptly and aborts it',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 30,
          });
          // /drip spreads 20 bytes over 8 seconds, so the body is nowhere
          // near done when the cancel lands and the next read is parked.
          final response = await platform
              .executeStreaming(live, <String, Object?>{
                'url': '/drip',
                'method': 'GET',
                'queryParams': <String, String>{
                  'duration': '8',
                  'numbytes': '20',
                },
              });

          final firstChunk = Completer<void>();
          final subscription = response.body.listen((chunk) {
            if (!firstChunk.isCompleted) {
              firstChunk.complete();
            }
          });
          await firstChunk.future.timeout(const Duration(seconds: 15));

          final stopwatch = Stopwatch()..start();
          await subscription
              .cancel()
              .timeout(const Duration(seconds: 5));
          stopwatch.stop();
          // The internally-owned cancel token interrupts the parked read;
          // waiting out the drip (8s) or the timeout (30s) fails the
          // timeout above.
          expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

          await platform.closeClient(live);
        },
      );

      test(
        'a live streamed upload round-trips, declared and chunked',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        () async {
          // /post echoes the body back as `data`, so the assertion proves
          // the chunks the source produced are the bytes that reached the
          // server, in order, under both framings the core can send: a
          // declared Content-Length and no length at all (DATA/FIN on H3).
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 30,
          });
          const parts = <String>['vane-', 'streamed-', 'upload'];
          final payload = parts.join();
          Stream<Uint8List> source() => Stream<Uint8List>.fromIterable(
            parts.map((part) => Uint8List.fromList(part.codeUnits)),
          );

          for (final declared in <int?>[payload.length, null]) {
            final response = await platform.execute(live, <String, Object?>{
              'url': '/post',
              'method': 'POST',
              'bodyStream': source(),
              'bodyStreamContentLength': declared,
            });
            expect(response.statusCode, 200);
            expect(response.httpVersion, VaneHttpVersion.http3);
            final echoed = jsonDecode(response.text) as Map<String, Object?>;
            expect(
              echoed['data'],
              payload,
              reason: declared == null
                  ? 'chunked/FIN framing must deliver the body intact'
                  : 'declared-length framing must deliver the body intact',
            );
          }

          await platform.closeClient(live);
        },
      );

      test(
        'a live streamed upload never runs ahead of the transport',
        skip: _liveBaseUrl() == null
            ? 'set VANE_TEST_BASE_URL to an https:// HTTP/3 host'
            : null,
        // package:test's default 30s would kill a 2 MiB WAN round-trip
        // before the request's own 60s deadline gets a say.
        timeout: const Timeout(Duration(seconds: 90)),
        () async {
          // The seam no other test spans: the upload pump's demand-driven
          // pull loop feeding the REAL core's blocking
          // vane_ffi_body_stream_write while a REAL network drains it. The
          // pump unit tests prove lockstep against a fake that acks writes
          // instantly, so a pump that buffered the whole source first would
          // look identical there. Here the drain gauge is the core's own
          // progress counter, read fresh at every pull (the production
          // 100 ms poller would be too stale at WAN throughput), so a
          // buffer-everything mutant records megabytes of overshoot before
          // the QUIC handshake can carry a single body byte.
          //
          // Why the bound cannot flake, fast or slow: pull k happens only
          // after write k-1 returned, and that write's admission required
          // the core's queue to be under BODY_STREAM_BUFFER_BYTES
          // (256 KiB), so consumed >= (k-1)*64KiB - 256KiB; uploadSent
          // trails consumed by at most two in-flight chunks on either
          // transport; hence produced <= sent + 256KiB + 3 chunks for a
          // correct pump — code-order arithmetic, not a race. The asserted
          // allowance adds three more chunks of slack: the generator runs
          // one yield ahead of its pause today, and a future 1-chunk
          // mailbox stage must not turn into a spurious failure. Slow
          // networks cannot fail it either — the bound is one-sided, so
          // the only slow-path exit is the request deadline.
          const chunkBytes = 64 * 1024;
          const chunkCount = 32; // 2 MiB total — 8x the core's buffer.
          const allowance = 256 * 1024 + 6 * chunkBytes;

          // A fresh client is a requirement, not tidiness: a connection
          // another test already warmed would start this upload with
          // different flow-control state, and closing the client below is
          // what tears the transfer down before the next test runs.
          final live = await platform.createClient(<String, Object?>{
            'baseUrl': _liveBaseUrl(),
            'timeoutSeconds': 60,
          });
          final progress = await platform.createProgress();
          final records = <({int produced, int sent})>[];
          final chunk = Uint8List.fromList(
            List<int>.filled(chunkBytes, 0x76), // ASCII 'v'
          );
          // Demand-driven by construction: the generator suspends at each
          // yield, and the upload pump pauses the subscription for the
          // duration of every native write. Recording only, no expects —
          // a failed assertion inside the source would wedge the upload.
          Stream<Uint8List> source() async* {
            for (var k = 0; k < chunkCount; k += 1) {
              final snapshot = await platform.progressSnapshot(progress);
              records.add(
                (produced: k * chunkBytes, sent: snapshot.uploadSent),
              );
              yield chunk;
            }
          }

          try {
            final response = await platform.execute(live, <String, Object?>{
              'url': '/post',
              'method': 'POST',
              'bodyStream': source(),
              'bodyStreamContentLength': chunkBytes * chunkCount,
              'progressId': progress,
            });
            // Deliberately not asserting httpVersion == http3: the
            // invariant is transport-agnostic, and pinning the protocol
            // would add an unrelated flake.
            expect(response.statusCode, 200);
            // Every chunk was pulled: an early-failing or short-circuited
            // upload cannot vacuously pass the bound below.
            expect(records.length, chunkCount);
            for (final record in records) {
              expect(
                record.produced,
                lessThanOrEqualTo(record.sent + allowance),
                reason:
                    'the source ran ${record.produced - record.sent} bytes '
                    'ahead of the transport (allowance: $allowance)',
              );
            }
          } finally {
            await platform.freeProgress(progress);
            await platform.closeClient(live);
          }
        },
      );

      test(
        'aborting a parked upload frees the native stream directly from '
        'this isolate, never through the writer mailbox',
        () async {
          // Pins the invariant that lives in [FfiVaneFlutter.startUpload]'s
          // `onFree` closure — the layer the driver unit tests cannot reach,
          // because they substitute their own `onFree`. Here the REAL
          // closure runs against the REAL registry: four 64 KiB chunks fill
          // the core's 256 KiB buffer exactly, the fifth write enters the
          // real `vane_ffi_body_stream_write` on the writer isolate and
          // parks (nothing consumes an unattached stream). The abort is
          // [UploadStreamDriver.dispose] — the exact call [execute]'s
          // finally makes when the request settles, and the only abort that
          // can reach a parked upload at all: the subscription is paused
          // during a write, so a source error is buffered undelivered until
          // the write acks. The registry itself is the witness: after the
          // dispose, `vane_ffi_body_stream_finish` on the id must report it
          // unknown — the direct free from this isolate already removed it.
          // A refactor that routes the free through the writer's mailbox
          // queues it behind the parked write forever; the id stays live,
          // finish returns Ok, and the assertion below fails.
          final probeLibrary = DynamicLibrary.open(libraryPath!);
          final probeFinish = probeLibrary.lookupFunction<
            Uint32 Function(Uint64, Pointer<_ProbeBuffer>),
            int Function(int, Pointer<_ProbeBuffer>)
          >('vane_ffi_body_stream_finish');
          final probeFree = probeLibrary
              .lookupFunction<Void Function(Uint64), void Function(int)>(
                'vane_ffi_body_stream_free',
              );
          final probeBufferFree = probeLibrary
              .lookupFunction<
                Void Function(_ProbeBuffer),
                void Function(_ProbeBuffer)
              >('vane_ffi_buffer_free');

          final controller = StreamController<Uint8List>();
          final upload = platform.startUpload(<String, Object?>{
            'url': 'https://upload.invalid/never-sent',
            'method': 'POST',
            'bodyStream': controller.stream,
          });
          expect(upload, isNotNull, reason: 'a bodyStream must start an upload');
          final id = upload!.request['bodyStreamId']! as int;
          expect(id, isNot(0));
          expect(
            upload.request.containsKey('bodyStream'),
            isFalse,
            reason: 'the unsendable Stream must be stripped from the map',
          );

          for (var chunk = 0; chunk < 5; chunk += 1) {
            controller.add(Uint8List(64 * 1024));
          }
          // Generous settle: isolate spawn plus four sub-millisecond native
          // writes plus the fifth entering its park. The discriminator only
          // needs the fifth write to be in flight when the abort lands.
          await Future<void>.delayed(const Duration(milliseconds: 1500));

          upload.driver.dispose();
          // The free is synchronous inside the driver's stop, so the
          // registry entry is gone before dispose returns; done latches in
          // the same call.
          await upload.driver.done.timeout(const Duration(seconds: 2));

          final probeError = calloc<_ProbeBuffer>();
          try {
            probeFinish(id, probeError);
            final length = probeError.ref.len;
            final message = length == 0
                ? ''
                : utf8.decode(probeError.ref.data.asTypedList(length));
            if (length != 0) {
              probeBufferFree(probeError.ref);
            }
            expect(
              message,
              contains('Unknown body stream id'),
              reason:
                  'the id must already be gone: onFree calls freeBodyStream '
                  'directly from this isolate while the writer is still '
                  'parked in its write — a mailbox-routed free would leave '
                  'the id alive here (finish would return Ok)',
            );
          } finally {
            calloc.free(probeError);
            // Unwedges a failing mutant's parked writer; a no-op on the
            // already-freed id the correct implementation leaves behind.
            probeFree(id);
          }
          await controller.close();
        },
      );
    },
  );
}
