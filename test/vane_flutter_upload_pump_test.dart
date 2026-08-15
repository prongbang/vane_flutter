import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_ffi.dart';

/// These tests exist to fail for an eager upload pump — the mirror of
/// `vane_flutter_stream_pump_test.dart`, whose lesson carries over verbatim:
/// delivery-side assertions prove nothing, because Dart's own buffering makes
/// every chunk "arrive" eventually whether or not anything paced it. The
/// write direction's discriminator is the SOURCE'S PRODUCTION COUNT. The
/// harness stands in for the core with manually-answered write acks — an
/// unanswered ack IS a write parked against a full send window — and an
/// implementation that accepts chunks faster than the core acknowledges them
/// lets the counting generator race ahead, which is the unbounded Dart-side
/// buffer the design forbids. The disciplined pump holds production in
/// lockstep with acks.
///
/// The second discriminator is teardown-while-parked: the native free is the
/// only thing that releases a writer blocked inside the native write, so it
/// must be reachable without waiting for the write. A teardown that awaits
/// the in-flight write (or queues the free behind it, as a copy of the
/// response pump's close-through-mailbox pattern would) never fires the free
/// here, and the assertion on [freeCalls] is what fails.
void main() {
  Future<void> spinEventLoop([int turns = 50]) async {
    for (var turn = 0; turn < turns; turn += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'the source is paused while a write is parked: production stays in '
    'lockstep with acks',
    () async {
      var produced = 0;
      Stream<Uint8List> source() async* {
        for (var index = 0; index < 100; index += 1) {
          produced += 1;
          yield Uint8List(64 * 1024);
        }
      }

      final acks = <Completer<void>>[];
      var completedAcks = 0;
      var finishCalls = 0;
      var freeCalls = 0;
      final driver = UploadStreamDriver(
        source: source(),
        onWrite: (chunk) {
          final ack = Completer<void>();
          acks.add(ack);
          return ack.future;
        },
        onFinish: () async {
          finishCalls += 1;
        },
        onFree: () {
          freeCalls += 1;
        },
      );

      // Write #1 parked (no ack): the generator must be suspended at its
      // yield. The async* machinery may sit one step past the delivered
      // chunk, so the bound is 2 — an eager subscription is at 100 here,
      // which is exactly the regression this expectation exists to catch.
      await spinEventLoop();
      expect(acks, hasLength(1), reason: 'exactly one write in flight');
      expect(
        produced,
        lessThanOrEqualTo(2),
        reason: 'the source ran ahead of the core: Dart-side buffering',
      );

      // Release acks one at a time: production advances in lockstep — one
      // ack, one new chunk, one new write — never more than the in-flight
      // chunk plus the generator's single step of lookahead.
      for (; completedAcks < 40; ) {
        acks[completedAcks].complete();
        completedAcks += 1;
        await spinEventLoop(10);
        expect(
          acks.length,
          completedAcks + 1,
          reason: 'exactly one write in flight after each ack',
        );
        expect(produced - completedAcks, lessThanOrEqualTo(2));
      }

      // Drain the rest: the source ends, finish runs once, free runs once,
      // and the total write count is exactly the chunk count.
      while (completedAcks < acks.length) {
        acks[completedAcks].complete();
        completedAcks += 1;
        await spinEventLoop(2);
      }
      await driver.done.timeout(const Duration(seconds: 5));
      expect(produced, 100);
      expect(acks, hasLength(100), reason: 'one write per chunk, no repeats');
      expect(finishCalls, 1);
      expect(freeCalls, 1, reason: 'a clean finish still releases the id');
      expect(driver.sourceError, isNull);

      // dispose after the driver's own terminal is a no-op.
      driver.dispose();
      expect(freeCalls, 1);
    },
  );

  test(
    'dispose while a write is parked frees the native stream immediately, '
    'without waiting the write out',
    () async {
      final parked = Completer<void>();
      var writesStarted = 0;
      var freeCalls = 0;
      final controller = StreamController<Uint8List>();
      final driver = UploadStreamDriver(
        source: controller.stream,
        onWrite: (chunk) {
          writesStarted += 1;
          return parked.future;
        },
        onFinish: () async {},
        onFree: () {
          freeCalls += 1;
        },
      );
      controller.add(Uint8List(8));
      await spinEventLoop(5);
      expect(writesStarted, 1);

      // The blocked-writer case from the design's risk list: dispose must
      // reach the free synchronously, with the write still unanswered. An
      // implementation that awaits the in-flight write — or routes the free
      // through the writer's own mailbox — leaves freeCalls at 0 here and
      // hangs forever in production, because only this free unparks the
      // writer.
      driver.dispose();
      expect(
        freeCalls,
        1,
        reason: 'free must fire from the non-parked path while the write '
            'is still blocked',
      );
      await driver.done.timeout(const Duration(seconds: 1));

      // The freed core releases the parked write with an error; that late
      // result belongs to a teardown the caller asked for and must be
      // swallowed. An unhandled async error here fails the test on its own.
      parked.completeError(
        const VaneHttpException('released', kind: VaneErrorKind.cancelled),
      );
      await spinEventLoop(5);
      expect(freeCalls, 1, reason: 'teardown ran exactly once');
      expect(writesStarted, 1, reason: 'no writes after teardown');
      await controller.close();
    },
  );

  test(
    'a source error aborts the upload and is recorded for the platform to '
    'report',
    () async {
      var freeCalls = 0;
      var finishCalls = 0;
      final controller = StreamController<Uint8List>();
      final driver = UploadStreamDriver(
        source: controller.stream,
        onWrite: (chunk) async {},
        onFinish: () async {
          finishCalls += 1;
        },
        onFree: () {
          freeCalls += 1;
        },
      );
      controller.add(Uint8List(4));
      await spinEventLoop(5);
      final failure = StateError('app source failed');
      controller.addError(failure);
      await driver.done.timeout(const Duration(seconds: 1));

      expect(driver.sourceError, same(failure), reason:
          'recorded so the platform reports the cause, not the induced '
          'Cancelled');
      expect(freeCalls, 1, reason: 'the abort is the free');
      expect(finishCalls, 0, reason: 'an errored body must never finish');
      await controller.close();
    },
  );

  test(
    'a core-failed write stops the pump quietly: the execute result is '
    'authoritative',
    () async {
      var produced = 0;
      Stream<Uint8List> source() async* {
        for (var index = 0; index < 50; index += 1) {
          produced += 1;
          yield Uint8List(16);
        }
      }

      var freeCalls = 0;
      var finishCalls = 0;
      final driver = UploadStreamDriver(
        source: source(),
        // The first write fails the way a released writer reports: with the
        // request's own error.
        onWrite: (chunk) => Future<void>.error(
          const VaneHttpException('request failed', kind: VaneErrorKind.timeout),
        ),
        onFinish: () async {
          finishCalls += 1;
        },
        onFree: () {
          freeCalls += 1;
        },
      );
      await driver.done.timeout(const Duration(seconds: 1));
      await spinEventLoop();

      expect(produced, lessThanOrEqualTo(2), reason:
          'a dead upload must stop pulling from the source');
      expect(freeCalls, 1);
      expect(finishCalls, 0);
      expect(driver.sourceError, isNull, reason:
          'a core-side failure is not the source\'s error; execute reports '
          'it');
    },
  );

  test('finish only runs after every write was acknowledged', () async {
    final order = <String>[];
    final acks = <Completer<void>>[];
    final controller = StreamController<Uint8List>();
    final driver = UploadStreamDriver(
      source: controller.stream,
      onWrite: (chunk) {
        order.add('write');
        final ack = Completer<void>();
        acks.add(ack);
        return ack.future;
      },
      onFinish: () async {
        order.add('finish');
      },
      onFree: () {
        order.add('free');
      },
    );
    controller
      ..add(Uint8List(1))
      ..add(Uint8List(1));
    // Closing with a write still unacknowledged: the done event must not
    // reach the driver (the subscription is paused), so finish cannot
    // overtake the outstanding write.
    unawaited(controller.close());
    await spinEventLoop(5);
    expect(order, <String>['write']);

    acks[0].complete();
    await spinEventLoop(5);
    expect(order, <String>['write', 'write']);

    acks[1].complete();
    await driver.done.timeout(const Duration(seconds: 1));
    expect(order, <String>['write', 'write', 'finish', 'free']);
  });
}
