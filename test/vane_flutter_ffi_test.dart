import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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
            allOf(contains('vane_ffi_abi_version'), contains('ABI v2')),
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
      /// branch against the real symbol, naming both versions.
      test('an ABI version mismatch is refused, naming both versions', () {
        final library = DynamicLibrary.open(libraryPath!);
        expect(verifyNativeAbi(library), same(library));
        expect(
          () => verifyNativeAbi(library, expected: 999),
          throwsA(
            isA<VaneHttpException>().having(
              (e) => e.message,
              'message',
              allOf(contains('ABI v2'), contains('v999')),
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
    },
  );
}
