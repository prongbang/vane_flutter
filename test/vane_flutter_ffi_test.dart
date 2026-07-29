import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  final libraryPath = _libraryPath();

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
    },
  );
}
