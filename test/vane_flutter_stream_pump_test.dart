import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';

/// These tests exist to fail for an eager pump. The design doc calls the
/// demand-driven pump the most likely piece to rot ("an eager loop looks
/// identical in a demo and buffers unboundedly in production"), so every
/// assertion here is chosen to distinguish the two: an implementation that
/// issues reads without waiting for demand blows straight through the pull
/// bounds below, while one that merely delivers the right bytes eventually
/// would pass a naive integrity check and prove nothing.
///
/// The supplier answers every pull instantly (in a microtask), which is the
/// worst case for buffering: any eagerness compounds at memory speed instead
/// of being masked by network latency.
void main() {
  /// Harness around the real [StreamBodyController] with an instant supplier
  /// and full accounting of pulls and shutdowns.
  ({
    StreamBodyController body,
    List<int> pulls,
    List<bool> aborts,
  })
  instantSupplier({
    int? eofAfter,
    Uint8List Function(int pull)? chunk,
  }) {
    final pulls = <int>[];
    final aborts = <bool>[];
    late final StreamBodyController body;
    body = StreamBodyController(
      onDemand: () {
        final pull = pulls.length + 1;
        pulls.add(pull);
        // An event-loop reply (Timer.run), matching how real pull results
        // arrive: as isolate port events. A synchronous or microtask reply
        // would be unfaithful in a way that matters — with an unpaused
        // consumer the pull/reply cycle would then never yield to the event
        // loop, and no timer (including the test timeout) could ever fire.
        Timer.run(() {
          if (eofAfter != null && pull > eofAfter) {
            body.addEof();
          } else {
            body.addChunk(chunk?.call(pull) ?? Uint8List(64 * 1024));
          }
        });
      },
      onShutdown: ({required bool abort}) async {
        aborts.add(abort);
      },
    );
    return (body: body, pulls: pulls, aborts: aborts);
  }

  Future<void> spinEventLoop([int turns = 200]) async {
    for (var turn = 0; turn < turns; turn += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('no listener means no pulls, ever', () async {
    final harness = instantSupplier();
    await spinEventLoop();
    expect(harness.pulls, isEmpty);
    // Silence the unused-stream lint honestly: it stays unlistened.
    expect(harness.body.stream.isBroadcast, isFalse);
  });

  test('a paused consumer stops the pulls at one chunk of overshoot',
      () async {
    final harness = instantSupplier();
    final delivered = <int>[];
    late final StreamSubscription<Uint8List> subscription;
    subscription = harness.body.stream.listen((chunk) {
      delivered.add(chunk.length);
      if (delivered.length == 1) {
        subscription.pause();
      }
    });

    // 200 event-loop turns against a supplier that answers instantly: an
    // eager pump racks up hundreds of pulls here and this expectation is
    // what fails. The demand-driven pump sits at exactly two — the pull the
    // listener consumed, plus the one already in flight when the pause
    // landed (its chunk is the single buffered overshoot).
    await spinEventLoop();
    expect(delivered, hasLength(1));
    expect(
      harness.pulls,
      hasLength(lessThanOrEqualTo(2)),
      reason: 'pulls while paused mean the pump is running ahead of demand',
    );
    final pullsWhilePaused = harness.pulls.length;

    // Resuming must restart demand — and pausing again must stop it again.
    subscription.resume();
    await spinEventLoop(20);
    expect(delivered.length, greaterThan(1));
    subscription.pause();
    await spinEventLoop(5);
    final pullsAtSecondPause = harness.pulls.length;
    await spinEventLoop();
    expect(harness.pulls.length - pullsAtSecondPause, lessThanOrEqualTo(1));
    expect(pullsWhilePaused, lessThanOrEqualTo(2));

    await subscription.cancel();
    expect(harness.aborts, <bool>[true],
        reason: 'a consumer cancel aborts exactly once, via the token');
  });

  test('pulls never run ahead of consumption by more than the one in flight',
      () async {
    final harness = instantSupplier();
    var consumed = 0;
    var maxLead = 0;
    await for (final _ in harness.body.stream) {
      consumed += 1;
      // await-for pauses the subscription across every await, so this loop
      // is the idiomatic slow consumer; the lead between pulls issued and
      // chunks consumed is the Dart-side buffer an eager pump grows without
      // bound and a demand-driven one caps at in-flight + one delivered.
      await Future<void>.delayed(Duration.zero);
      final lead = harness.pulls.length - consumed;
      maxLead = lead > maxLead ? lead : maxLead;
      if (consumed == 30) {
        break;
      }
    }
    expect(consumed, 30);
    expect(
      maxLead,
      lessThanOrEqualTo(2),
      reason: 'the pump read ahead of the consumer: Dart-side buffering',
    );
    // Breaking out of await-for cancels the subscription: a live stream
    // being cancelled by its consumer is an abort.
    await spinEventLoop(5);
    expect(harness.aborts, <bool>[true]);
  });

  test('EOF closes the stream and shuts down without aborting', () async {
    final harness = instantSupplier(
      eofAfter: 3,
      chunk: (pull) => Uint8List.fromList(<int>[pull]),
    );
    final chunks = await harness.body.stream.toList();
    expect(chunks.map((chunk) => chunk.single), <int>[1, 2, 3]);
    // The done event's implicit cancel runs the shutdown; it must not carry
    // the abort flag — a normal end of stream may never cancel the caller's
    // token out from under a later request.
    await spinEventLoop(5);
    expect(harness.aborts, <bool>[false]);
  });

  test('a terminal failure surfaces once, then the stream is done', () async {
    final pulls = <int>[];
    final aborts = <bool>[];
    late final StreamBodyController body;
    body = StreamBodyController(
      onDemand: () {
        pulls.add(pulls.length + 1);
        Timer.run(() {
          if (pulls.length == 1) {
            body.addChunk(Uint8List.fromList(<int>[7]));
          } else {
            body.addFailure(
              const VaneHttpException('mid-stream', kind: VaneErrorKind.timeout),
            );
          }
        });
      },
      onShutdown: ({required bool abort}) async {
        aborts.add(abort);
      },
    );

    final delivered = <int>[];
    Object? failure;
    var done = false;
    body.stream.listen(
      (chunk) => delivered.add(chunk.single),
      onError: (Object error) => failure = error,
      onDone: () => done = true,
    );
    await spinEventLoop(20);

    expect(delivered, <int>[7]);
    expect(
      failure,
      isA<VaneHttpException>()
          .having((e) => e.kind, 'kind', VaneErrorKind.timeout),
    );
    expect(done, isTrue);
    expect(aborts, <bool>[false],
        reason: 'the stream failed on its own; there is nothing to abort');
    expect(pulls, hasLength(2), reason: 'a dead stream must not be pulled');
  });

  test('a pull in flight when the consumer cancels is dropped, not delivered',
      () async {
    final pulls = <Completer<void>>[];
    final aborts = <bool>[];
    late final StreamBodyController body;
    body = StreamBodyController(
      // Answered manually, so the test controls exactly when each pull
      // resolves relative to the cancel.
      onDemand: () => pulls.add(Completer<void>()),
      onShutdown: ({required bool abort}) async {
        aborts.add(abort);
      },
    );

    final delivered = <int>[];
    Object? failure;
    final subscription = body.stream.listen(
      (chunk) => delivered.add(chunk.single),
      onError: (Object error) => failure = error,
    );
    await spinEventLoop(2);
    expect(pulls, hasLength(1));
    body.addChunk(Uint8List.fromList(<int>[1]));
    await spinEventLoop(2);
    expect(delivered, <int>[1]);
    expect(pulls, hasLength(2), reason: 'consumption re-arms demand');

    // Cancel with pull #2 still unanswered — the blocked-read case. The
    // cancel must not wait for the pull, and the pull's eventual result
    // (here: the Cancelled error the interrupted read reports) must be
    // swallowed, because the consumer asked for exactly that.
    await subscription.cancel();
    expect(aborts, <bool>[true]);
    body.addFailure(
      const VaneHttpException('cancelled', kind: VaneErrorKind.cancelled),
    );
    await spinEventLoop(2);
    expect(failure, isNull);
    expect(delivered, <int>[1]);
    expect(pulls, hasLength(2), reason: 'no demand after cancel');
  });
}
