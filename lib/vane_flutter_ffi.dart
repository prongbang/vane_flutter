import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http_profile/http_profile.dart';
import 'package:meta/meta.dart';

import 'vane_flutter.dart';
import 'vane_flutter_platform_interface.dart';

final class _VaneFfiString extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;
}

final class _VaneFfiStringPair extends Struct {
  external _VaneFfiString key;
  external _VaneFfiString value;
}

final class _VaneFfiStringList extends Struct {
  external Pointer<_VaneFfiString> values;

  @Size()
  external int len;
}

final class _VaneFfiStringListPair extends Struct {
  external _VaneFfiString key;
  external _VaneFfiStringList values;
}

final class _VaneFfiClientConfig extends Struct {
  external _VaneFfiString baseUrl;
  external Pointer<_VaneFfiStringPair> defaultHeaders;

  @Size()
  external int defaultHeadersLen;

  external Pointer<_VaneFfiStringPair> dnsOverrides;

  @Size()
  external int dnsOverridesLen;

  external Pointer<_VaneFfiStringListPair> certificatePins;

  @Size()
  external int certificatePinsLen;

  @Bool()
  external bool cookiesEnabled;

  external _VaneFfiString cookiePersistencePath;

  @Bool()
  external bool connectionPoolEnabled;

  @Uint64()
  external int maxIdleConnections;

  @Uint64()
  external int connectionIdleTimeoutSeconds;

  @Uint64()
  external int retryMaxAttempts;

  @Uint64()
  external int retryInitialDelayMillis;

  @Uint64()
  external int retryMaxDelayMillis;

  @Bool()
  external bool retryUnsafeMethods;

  @Uint64()
  external int maxRequestBodyBytes;

  @Uint64()
  external int maxResponseBodyBytes;

  @Int64()
  external int timeoutSeconds;

  @Bool()
  external bool followRedirects;

  external _VaneFfiString userAgent;

  @Uint8()
  external int protocolMode;

  external _VaneFfiString proxyUrl;
  external _VaneFfiString proxyAuthorization;

  // -------- appended in ABI v5; declaration order IS the offset --------

  /// Redirect hop cap; callers pass 10 for the default. Values > 64 are
  /// rejected at client creation.
  @Uint32()
  external int maxRedirects;

  /// 0 = unset, 12 = TLS 1.2, 13 = TLS 1.3. Anything else is an error.
  @Uint8()
  external int tlsMinVersion;

  @Uint8()
  external int tlsMaxVersion;

  // 2 bytes tail padding here before the next 8-aligned pointer — deliberate;
  // do NOT fill them later without a bump (the VaneFfiResponse padding
  // lesson).

  /// Concatenated PEM bundle; empty = none. Becomes a one-element
  /// custom_root_certificates vec in the core (PEM is concatenation-safe).
  external _VaneFfiString customRootCaPem;

  /// PEM leaf-first chain; empty = none. Must be set together with the key.
  external _VaneFfiString clientCertificatePem;
  external _VaneFfiString clientPrivateKeyPem;
}

final class _VaneFfiRequest extends Struct {
  external _VaneFfiString url;
  external _VaneFfiString method;
  external Pointer<_VaneFfiStringPair> headers;

  @Size()
  external int headersLen;

  external Pointer<_VaneFfiStringPair> queryParams;

  @Size()
  external int queryParamsLen;

  external _VaneFfiString bodyFilePath;
  external _VaneFfiString responseBodyPath;

  @Uint64()
  external int cancelTokenId;

  @Uint64()
  external int progressId;

  @Int64()
  external int timeoutSeconds;

  @Bool()
  external bool followRedirects;

  /// `vane_ffi_body_stream_create` id the request's body streams from; 0 =
  /// none. Appended in ABI v4 — declaration order IS the offset here, and
  /// Rust appends it after `follow_redirects` (a u64 cannot ride the seven
  /// tail-padding bytes, so the struct grew rather than absorbing it).
  /// Declaring it anywhere but last would desync every field behind it,
  /// silently.
  @Uint64()
  external int bodyStreamId;
}

final class _VaneFfiBuffer extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;

  @Size()
  external int cap;
}

final class _VaneFfiHeader extends Struct {
  external _VaneFfiBuffer key;
  external _VaneFfiBuffer value;
}

final class _VaneFfiHeaderArray extends Struct {
  external Pointer<_VaneFfiHeader> data;

  @Size()
  external int len;

  @Size()
  external int cap;
}

final class _VaneFfiResponse extends Struct {
  @Uint16()
  external int statusCode;

  @Bool()
  external bool isSuccess;

  /// `VaneHttpVersion::ffi_code`; 0 when the protocol is not known. Declared
  /// between [isSuccess] and [errorKind] because declaration order IS the
  /// offset here, and Rust puts it at offset 3 — the one free padding byte.
  /// Declaring it last would place it past the struct and read garbage,
  /// silently.
  @Uint8()
  external int httpVersion;

  /// `VaneError::ffi_kind` for [error]; 0 when there is no error. Declared here
  /// because Rust puts it here, in the padding after `is_success`.
  @Uint32()
  external int errorKind;

  external _VaneFfiHeaderArray headers;
  external _VaneFfiBuffer body;
  external _VaneFfiBuffer bodyFilePath;
  external _VaneFfiBuffer url;
  external _VaneFfiBuffer error;

  /// IP literal of the socket peer ("203.0.113.7"); empty = unknown. Appended
  /// in ABI v5 — the padding after [isSuccess] was spent in v3, so this GROWS
  /// the struct. Always empty until batch 2 of the v5 rollout fills it (and
  /// the response model starts reading it); declared now because the layout
  /// is the v5 contract. Freed with the rest of the response by
  /// `vane_ffi_response_free`.
  external _VaneFfiBuffer remoteIp;
}

final class _VaneFfiProgress extends Struct {
  @Uint64()
  external int uploadSent;

  @Uint64()
  external int uploadTotal;

  @Uint64()
  external int downloadReceived;

  @Uint64()
  external int downloadTotal;

  @Bool()
  external bool done;
}

/// One blocking pull off a response stream; mirrors `VaneFfiStreamChunk`.
/// Exactly one of three shapes: a body chunk (both flags clear), end of body
/// ([eof]), or a terminal failure ([error] non-empty, [errorKind] set). The
/// caller owns and frees whichever buffers came back non-empty.
final class _VaneFfiStreamChunk extends Struct {
  external _VaneFfiBuffer body;
  external _VaneFfiBuffer error;

  @Uint32()
  external int errorKind;

  @Bool()
  external bool eof;
}

typedef _ClientCreateNative =
    Uint64 Function(
      Pointer<_VaneFfiClientConfig>,
      Pointer<_VaneFfiBuffer>,
      Pointer<Uint32>,
    );
typedef _ClientCreateDart =
    int Function(
      Pointer<_VaneFfiClientConfig>,
      Pointer<_VaneFfiBuffer>,
      Pointer<Uint32>,
    );
typedef _ClientCloseNative = Void Function(Uint64);
typedef _ClientCloseDart = void Function(int);
typedef _SetCertificatePinsNative =
    Bool Function(
      Uint64,
      _VaneFfiString,
      _VaneFfiStringList,
      Pointer<_VaneFfiBuffer>,
    );
typedef _SetCertificatePinsDart =
    bool Function(
      int,
      _VaneFfiString,
      _VaneFfiStringList,
      Pointer<_VaneFfiBuffer>,
    );
typedef _ExecuteNative =
    Pointer<_VaneFfiResponse> Function(
      Uint64,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      Size,
    );
typedef _ExecuteDart =
    Pointer<_VaneFfiResponse> Function(
      int,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      int,
    );
typedef _ResponseFreeNative = Void Function(Pointer<_VaneFfiResponse>);
typedef _ResponseFreeDart = void Function(Pointer<_VaneFfiResponse>);
typedef _BufferFreeNative = Void Function(_VaneFfiBuffer);
typedef _BufferFreeDart = void Function(_VaneFfiBuffer);
typedef _IdCreateNative = Uint64 Function();
typedef _IdCreateDart = int Function();
typedef _IdActionNative = Void Function(Uint64);
typedef _IdActionDart = void Function(int);
typedef _ProgressSnapshotNative = _VaneFfiProgress Function(Uint64);
typedef _ProgressSnapshotDart = _VaneFfiProgress Function(int);
typedef _WarmupNative = Void Function(Uint64, _VaneFfiString);
typedef _WarmupDart = void Function(int, _VaneFfiString);
typedef _ExecuteStreamingNative =
    Pointer<_VaneFfiResponse> Function(
      Uint64,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint64>,
    );
typedef _ExecuteStreamingDart =
    Pointer<_VaneFfiResponse> Function(
      int,
      Pointer<_VaneFfiRequest>,
      Pointer<Uint8>,
      int,
      Pointer<Uint64>,
    );
typedef _StreamReadNative = _VaneFfiStreamChunk Function(Uint64);
typedef _StreamReadDart = _VaneFfiStreamChunk Function(int);
typedef _StreamCloseNative = Void Function(Uint64);
typedef _StreamCloseDart = void Function(int);
typedef _BodyStreamCreateNative = Uint64 Function(Int64);
typedef _BodyStreamCreateDart = int Function(int);
typedef _BodyStreamWriteNative =
    Uint32 Function(Uint64, Pointer<Uint8>, Size, Pointer<_VaneFfiBuffer>);
typedef _BodyStreamWriteDart =
    int Function(int, Pointer<Uint8>, int, Pointer<_VaneFfiBuffer>);
typedef _BodyStreamFinishNative = Uint32 Function(Uint64, Pointer<_VaneFfiBuffer>);
typedef _BodyStreamFinishDart = int Function(int, Pointer<_VaneFfiBuffer>);

/// The C ABI version this package's structs and calls were written against.
/// Rust exports the native side as `vane_ffi_abi_version`; the two must match
/// exactly, because every `_VaneFfi*` struct here mirrors its Rust layout by
/// hand and a skewed layout reads garbage — or frees wild pointers —
/// silently. Bump in lockstep with the Rust constant.
///
/// v2: `vane_ffi_client_warmup` — this package binds the symbol, so a v1
/// library cannot serve it and must be rejected with the clear version
/// message rather than a symbol-lookup failure.
///
/// v3: response-body streaming — `vane_ffi_execute_streaming`,
/// `vane_ffi_stream_read`, `vane_ffi_stream_close` and the
/// `VaneFfiStreamChunk` struct this package mirrors as
/// [_VaneFfiStreamChunk].
///
/// v4: request-body (upload) streaming — `vane_ffi_body_stream_create`,
/// `vane_ffi_body_stream_write`, `vane_ffi_body_stream_finish`,
/// `vane_ffi_body_stream_free`, and `_VaneFfiRequest` gained
/// `bodyStreamId`. That was a struct GROWTH, not a padding fill: a v3
/// library reading this package's request struct — or the reverse — would
/// misread past the end, which is precisely the skew this constant refuses.
///
/// v5: the config knobs — `_VaneFfiClientConfig` gained `maxRedirects`,
/// `tlsMinVersion`/`tlsMaxVersion`, `customRootCaPem`,
/// `clientCertificatePem`/`clientPrivateKeyPem`; `_VaneFfiResponse` gained
/// `remoteIp` (a struct GROWTH, like v4's); `vane_ffi_client_create` gained
/// an `out_error_kind` out-param — a SIGNATURE change, so a skewed pairing
/// would corrupt the call frame, not just misread a struct — and the DNS
/// resolver symbols (`vane_ffi_set_dns_resolver`,
/// `vane_ffi_dns_resolver_reply`) joined the contract as stubs.
const int _expectedAbiVersion = 5;

/// Verifies the native library speaks this package's C ABI, and returns it.
///
/// Runs before any other symbol is bound. A missing symbol means the loaded
/// core predates ABI versioning (or is not libvane at all) — the same skew
/// case as a wrong number, and packaging skew has shipped before, so both
/// fail loudly here instead of corrupting memory later. [expected] exists for
/// tests; production callers pass nothing.
@visibleForTesting
DynamicLibrary verifyNativeAbi(
  DynamicLibrary library, {
  int expected = _expectedAbiVersion,
}) {
  final int version;
  try {
    version = library.lookupFunction<Uint32 Function(), int Function()>(
      'vane_ffi_abi_version',
      isLeaf: true,
    )();
  } on ArgumentError {
    throw VaneHttpException(
      'native libvane does not export vane_ffi_abi_version — the loaded '
      'library is missing or predates ABI versioning; this package expects '
      'ABI v$expected. Rebuild/update libvane and this package so they '
      'match.',
    );
  }
  if (version != expected) {
    throw VaneHttpException(
      'native libvane ABI v$version, this package expects v$expected — '
      'rebuild/update libvane and this package so they match.',
    );
  }
  return library;
}

class FfiVaneFlutter extends VaneFlutterPlatform {
  FfiVaneFlutter({this._library});

  final DynamicLibrary? _library;

  late final DynamicLibrary _resolvedLibrary = verifyNativeAbi(
    _library ?? _openLibrary(),
  );
  late final _VaneFfiBindings _nativeBindings = _VaneFfiBindings(
    _resolvedLibrary,
  );
  _VaneWorkerPool? _workerPool;

  _VaneWorkerPool get _workers =>
      _workerPool ??= _VaneWorkerPool(_resolvedLibrary);

  /// Releases the worker isolates and their ports. Deliberately not on
  /// [VaneFlutterPlatform]: workers are shared by every client, so this is for
  /// test teardown (or a host that owns this instance directly), not for
  /// closing a single client — use [closeClient] for that. Idempotent; a later
  /// request just spawns a fresh worker.
  void dispose() {
    _workerPool?.dispose();
    _workerPool = null;
  }

  /// Base URLs by client handle, kept only so a profiled request can be
  /// reported under its absolute URL — Rust still owns the actual join.
  final Map<int, String> _baseUrls = <int, String>{};

  @override
  Future<int> createClient(Map<String, Object?> configuration) async {
    final handle = _nativeBindings.createClient(configuration);
    final baseUrl = configuration['baseUrl'] as String?;
    if (baseUrl != null && baseUrl.isNotEmpty) {
      _baseUrls[handle] = baseUrl;
    }
    return handle;
  }

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    // Extracted before anything else touches the map: a Stream cannot cross
    // the worker isolate boundary, so the upload rides as a native stream id
    // while this isolate pumps the caller's source into it.
    final upload = startUpload(request);
    if (upload != null) {
      request = upload.request;
    }
    // With DevTools profiling off — the default — this whole feature costs one
    // static bool read and the null checks below. Nothing is allocated and the
    // response body is never touched.
    HttpClientRequestProfile? profile;
    if (HttpClientRequestProfile.profilingEnabled) {
      // Profiling is never load-bearing: recording a request must not be able
      // to change, delay or fail it.
      try {
        profile = await _startProfile(request, _baseUrls[handle]);
      } catch (_) {
        profile = null;
      }
    }
    try {
      // The worker only runs the blocking native call and hands back the
      // response pointer; decoding happens here so the body can stay a view
      // over the native buffer.
      final address = await _workers.execute(handle, request);
      // The core is one blocking call, so this is the earliest observable
      // moment of the response — not a true first-byte timestamp.
      final responseTime = profile == null ? null : DateTime.now();
      final response = _nativeBindings.readResponse(address);
      if (profile != null) {
        try {
          await _finishProfile(profile, response, responseTime);
        } catch (_) {
          // A recording failure must not turn a good response into an error.
        }
      }
      return response;
    } catch (error, stackTrace) {
      if (profile != null) {
        try {
          await profile.responseData.closeWithError(error.toString());
        } catch (_) {
          // Never let a recording failure mask the real error.
        }
      }
      // The caller's source stream failing is what aborted the upload, and
      // the abort is what failed the request (as `Cancelled`) — so the
      // source's own error is the story, not the synthetic one it induced.
      final sourceError = upload?.driver.sourceError;
      if (sourceError != null) {
        Error.throwWithStackTrace(
          sourceError,
          upload!.driver.sourceStackTrace ?? stackTrace,
        );
      }
      rethrow;
    } finally {
      // The exchange is over either way; a still-live driver (server
      // answered early, or the request failed while the source was idle)
      // must not keep the source subscribed. Idempotent, and a no-op on the
      // native side after a clean finish.
      upload?.driver.dispose();
    }
  }

  /// Sets up the caller-pushed body stream when [request] carries one:
  /// creates the native stream, spawns its writer isolate, and starts the
  /// [UploadStreamDriver] pumping the caller's source into it. Returns the
  /// map to actually send — the unsendable `Stream` stripped, the native id
  /// in its place — or null when there is nothing to stream.
  ///
  /// Public only for the teardown-while-parked test in
  /// `test/vane_flutter_ffi_test.dart`, which pins the `onFree` closure
  /// below against the real registry: the free must be the DIRECT native
  /// call from this isolate, and rerouting it through the writer's mailbox
  /// would queue it behind the very write it must interrupt. Production
  /// reaches this only through [execute] and [executeStreaming].
  @visibleForTesting
  ({Map<String, Object?> request, UploadStreamDriver driver})? startUpload(
    Map<String, Object?> request,
  ) {
    final source = request['bodyStream'];
    if (source == null) {
      return null;
    }
    // Both casts before anything native is allocated: a wrongly-typed map
    // value must throw here, not leak a registry id.
    final stream = source as Stream<Uint8List>;
    final contentLength = request['bodyStreamContentLength'] as int?;
    final id = _nativeBindings.createBodyStream(contentLength);
    final writer = _VaneUploadWriter(_resolvedLibrary, id);
    final driver = UploadStreamDriver(
      source: stream,
      onWrite: writer.write,
      onFinish: writer.finish,
      onFree: () {
        // The direct registry call, from this never-parked isolate. The
        // writer may be parked inside the blocked native write, and this
        // free is the only thing that releases it — routing it through the
        // writer's mailbox would queue it behind the very call it must
        // interrupt. Pinned against the real registry by the
        // teardown-while-parked test in `test/vane_flutter_ffi_test.dart`.
        _nativeBindings.freeBodyStream(id);
        writer.close();
      },
    );
    final stripped = <String, Object?>{...request}
      ..remove('bodyStream')
      ..remove('bodyStreamContentLength');
    stripped['bodyStreamId'] = id;
    return (request: stripped, driver: driver);
  }

  /// One pump isolate per stream, spawned here and owned by the returned
  /// body: the worker pool stays free for ordinary requests, and the pump's
  /// single-read-per-demand protocol is what keeps a slow consumer from
  /// buffering on the Dart side (see [StreamBodyController]).
  ///
  /// Not profiled: DevTools recording is built around buffered
  /// request/response pairs; wiring a live body into it is future work.
  @override
  Future<VaneStreamingResponse> executeStreaming(
    int handle,
    Map<String, Object?> request,
  ) async {
    // Same extraction as [execute]. The upload driver and the response pump
    // are separate isolates making independent blocking calls, so a request
    // can stream in both directions at once.
    final upload = startUpload(request);
    if (upload != null) {
      request = upload.request;
    }
    var tokenId = (request['cancelTokenId'] as int?) ?? 0;
    var ownsToken = false;
    if (tokenId == 0) {
      // A streaming request always runs with a cancel token: cancelling the
      // token is what interrupts a pull blocked inside the native read when
      // the consumer cancels — close alone would wait the read out. Owned
      // here and freed when the pump finishes.
      tokenId = _nativeBindings.createCancelToken();
      ownsToken = true;
      request = <String, Object?>{...request, 'cancelTokenId': tokenId};
    }
    try {
      return await _VaneStreamPump(
        _nativeBindings,
        _resolvedLibrary,
        handle,
        request,
        cancelTokenId: tokenId,
        ownsCancelToken: ownsToken,
      ).start();
    } catch (error, stackTrace) {
      // The request died at or before the headers, so the upload is over
      // too. Same source-error precedence as [execute].
      upload?.driver.dispose();
      final sourceError = upload?.driver.sourceError;
      if (sourceError != null) {
        Error.throwWithStackTrace(
          sourceError,
          upload!.driver.sourceStackTrace ?? stackTrace,
        );
      }
      rethrow;
    }
    // No dispose on success, deliberately: an HTTP/3 server that answers
    // early leaves the upload legitimately still pumping after the head
    // arrives, and the driver tears itself down on its own terminal (clean
    // finish, a write the core failed, or the source ending). A source that
    // simply goes silent after the request dies is bounded by the request
    // timeout: the core's release latch fails the next write.
  }

  @override
  Future<void> closeClient(int handle) async {
    _baseUrls.remove(handle);
    _nativeBindings.closeClient(handle);
  }

  @override
  Future<void> setCertificatePins(
    int handle,
    String host,
    List<String> pins,
  ) async {
    _nativeBindings.setCertificatePins(handle, host, pins);
  }

  @override
  Future<void> warmup(int handle, String? url) {
    // The native call blocks for up to the client timeout (runtime and
    // trust-store setup plus a handshake), so it runs off this isolate. A
    // one-shot Isolate.run rather than the worker pool: warmup happens about
    // once per app launch, and the pool's protocol is execute-shaped. Only
    // the raw symbol pointer can cross the isolate boundary; resolving it
    // here also means the ABI check has already run.
    final warmupPointer = _resolvedLibrary
        .lookup<NativeFunction<_WarmupNative>>('vane_ffi_client_warmup');
    return Isolate.run(() {
      final warmup = warmupPointer.asFunction<_WarmupDart>();
      final nativeUrl = _NativeString(url);
      final value = calloc<_VaneFfiString>();
      try {
        nativeUrl.writeTo(value.ref);
        warmup(handle, value.ref);
      } finally {
        calloc.free(value);
        nativeUrl.free();
      }
    });
  }

  @override
  Future<int> createCancelToken() async {
    return _nativeBindings.createCancelToken();
  }

  @override
  Future<void> cancelToken(int id) async {
    _nativeBindings.cancelToken(id);
  }

  @override
  Future<void> freeCancelToken(int id) async {
    _nativeBindings.freeCancelToken(id);
  }

  @override
  Future<int> createProgress() async {
    return _nativeBindings.createProgress();
  }

  @override
  Future<VaneProgress> progressSnapshot(int id) async {
    return _nativeBindings.progressSnapshot(id);
  }

  @override
  Future<void> freeProgress(int id) async {
    _nativeBindings.freeProgress(id);
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libvane.so');
    }
    throw UnsupportedError('Vane FFI is not supported on this platform.');
  }
}

/// Worker isolates for the blocking native call, spawned on demand and reused.
class _VaneWorkerPool {
  _VaneWorkerPool(this._library);

  // ponytail: 4 workers. Each one is an isolate blocked in Rust for the whole
  // request, so the cap is about how many requests may overlap, not cores;
  // beyond it requests queue on the least busy worker. Raise it if profiles
  // show real queueing.
  static const int _maxWorkers = 4;

  final DynamicLibrary _library;
  final List<_VaneWorker> _workers = <_VaneWorker>[];

  Future<int> execute(int handle, Map<String, Object?> request) {
    return _pick().execute(handle, request);
  }

  _VaneWorker _pick() {
    _workers.removeWhere((worker) => worker.isDead);
    if (_workers.isEmpty) {
      return _spawn();
    }
    final idlest = _workers.reduce((a, b) => b.inFlight < a.inFlight ? b : a);
    if (idlest.inFlight > 0 && _workers.length < _maxWorkers) {
      return _spawn();
    }
    return idlest;
  }

  _VaneWorker _spawn() {
    final worker = _VaneWorker(_library);
    _workers.add(worker);
    return worker;
  }

  void dispose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }
}

/// Long-lived isolate that runs the blocking `vane_ffi_execute` call off the
/// calling isolate. The symbol is resolved once at spawn and handed over as a
/// pointer (a `DynamicLibrary` cannot cross isolates, so this is also what
/// keeps an injected test library in effect); requests are id-tagged so
/// concurrent callers multiplex over one worker.
class _VaneWorker {
  _VaneWorker(DynamicLibrary library) {
    _responses.listen(_onResponse);
    _ready =
        Isolate.spawn(
          _main,
          (
            _responses.sendPort,
            library.lookup<NativeFunction<_ExecuteNative>>('vane_ffi_execute'),
          ),
          // Without these an isolate that dies takes every request routed to it
          // with it, silently, and those futures never complete.
          onExit: _responses.sendPort,
          onError: _responses.sendPort,
        ).then((isolate) {
          _isolate = isolate;
          return _commands.future;
        });
    // A failed spawn has to retire the worker too; callers still see the error
    // through their own `await _ready`.
    _ready.then<void>((_) {}, onError: _die);
  }

  final ReceivePort _responses = ReceivePort();
  final Completer<SendPort> _commands = Completer<SendPort>();
  final Map<int, Completer<int>> _pending = <int, Completer<int>>{};
  late final Future<SendPort> _ready;
  Isolate? _isolate;
  int _nextId = 0;
  int _inFlight = 0;
  bool _dead = false;

  int get inFlight => _inFlight;

  bool get isDead => _dead;

  /// Completes with the address of the native response, which the caller then
  /// owns and must free (directly or through a finalizer).
  Future<int> execute(int handle, Map<String, Object?> request) async {
    _inFlight += 1;
    try {
      final commands = await _ready;
      final id = _nextId += 1;
      // Send first: an unsendable value in the request map throws here, and a
      // completer registered before that would never be completed or removed.
      commands.send((id, handle, request));
      final completer = Completer<int>();
      _pending[id] = completer;
      return await completer.future;
    } finally {
      _inFlight -= 1;
    }
  }

  void dispose() {
    _die(const VaneHttpException('Vane worker isolate was disposed.'));
  }

  void _onResponse(Object? message) {
    if (message is SendPort) {
      _commands.complete(message);
      return;
    }
    if (message == null || message is List) {
      // onExit sends null, onError sends [error, stackTrace]. Either way the
      // isolate is gone.
      _die(
        VaneHttpException(
          message is List
              ? 'Vane worker isolate died: ${message.first}'
              : 'Vane worker isolate exited unexpectedly.',
        ),
        message is List && message.length > 1
            ? StackTrace.fromString('${message[1]}')
            : null,
      );
      return;
    }
    final (id, address, error, stackTrace) =
        message as (int, int, String?, String?);
    final completer = _pending.remove(id);
    if (completer == null) {
      return;
    }
    if (error != null) {
      completer.completeError(
        VaneHttpException(error),
        StackTrace.fromString(stackTrace ?? ''),
      );
    } else {
      completer.complete(address);
    }
  }

  /// The worker is gone — exited, crashed, failed to spawn, or disposed. Fail
  /// everything routed to it so callers get an error instead of a future that
  /// never completes, and let the pool retire it. `_inFlight` is left to the
  /// `finally` in [execute], which drains it exactly once per call.
  ///
  /// A native response still in flight is leaked: its reply lands on a closed
  /// port with no one left to free it. Bounded by the requests outstanding at
  /// teardown, so it is not worth a drain protocol.
  void _die(Object error, [StackTrace? stackTrace]) {
    if (_dead) {
      return;
    }
    _dead = true;
    if (!_commands.isCompleted) {
      _commands.completeError(error, stackTrace);
    }
    for (final completer in _pending.values) {
      completer.completeError(error, stackTrace);
    }
    _pending.clear();
    _responses.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  static void _main((SendPort, Pointer<NativeFunction<_ExecuteNative>>) init) {
    final (responses, executePointer) = init;
    // Bound once per worker instead of once per request.
    final execute = executePointer.asFunction<_ExecuteDart>();
    final commands = ReceivePort();
    responses.send(commands.sendPort);
    commands.listen((Object? message) {
      // Everything, including the destructuring, is inside the try: an error
      // escaping this callback kills the isolate and leaves the caller's future
      // pending forever.
      var id = 0;
      _NativeRequest? nativeRequest;
      try {
        final (requestId, handle, request) =
            message as (int, int, Map<String, Object?>);
        id = requestId;
        nativeRequest = _NativeRequest(request);
        final response = execute(
          handle,
          nativeRequest.pointer,
          nativeRequest.body.pointer,
          nativeRequest.body.length,
        );
        responses.send((id, response.address, null, null));
      } catch (error, stackTrace) {
        // Strings only: sending an arbitrary caught object can itself throw
        // (unsendable), which would kill the worker while reporting a failure.
        responses.send((id, 0, error.toString(), stackTrace.toString()));
      } finally {
        nativeRequest?.free();
      }
    });
  }
}

/// The demand side of a streamed response body: turns the single listener's
/// listen/pause/resume/cancel signals into single-pull requests against a
/// pump that runs exactly one blocking native read per request.
///
/// The whole value of this class is the discipline [_maybeRequest] encodes:
/// at most ONE pull in flight, and none while the consumer is paused, gone,
/// or the stream has ended. An eager loop here would look identical on a
/// demo and buffer without bound in production, silently defeating the
/// transport backpressure the core's pull design exists to provide —
/// `test/vane_flutter_stream_pump_test.dart` is written to fail if that
/// regresses. Overshoot is bounded at one chunk: a pull already in flight
/// when the consumer pauses cannot be un-issued, so its result is buffered
/// by the controller and delivered on resume.
///
/// Public only for that test; everything else reaches streaming through
/// [FfiVaneFlutter.executeStreaming].
@visibleForTesting
final class StreamBodyController {
  StreamBodyController({
    required this._onDemand,
    required this._onShutdown,
  }) {
    _controller = StreamController<Uint8List>(
      onListen: _maybeRequest,
      onResume: _maybeRequest,
      // No onPause body: not requesting is the entire reaction to a pause.
      onCancel: _cancel,
    );
  }

  /// Ask the pump for exactly one chunk. Never called with one outstanding.
  final void Function() _onDemand;

  /// Tear the native stream down. `abort` is true only when a live stream is
  /// being cancelled by the consumer — that is the case that must interrupt
  /// a blocked read via the cancel token; after EOF or an error there is
  /// nothing to interrupt and the caller's token must NOT be cancelled by a
  /// normal end of stream.
  final Future<void> Function({required bool abort}) _onShutdown;

  late final StreamController<Uint8List> _controller;

  /// One pull requested and not yet answered.
  bool _pullInFlight = false;

  /// The native side finished (EOF or terminal error) on its own.
  bool _terminal = false;

  /// Set by the first cancel; replayed to every later one.
  Future<void>? _shutdown;

  /// Single-subscription body stream handed to the caller.
  Stream<Uint8List> get stream => _controller.stream;

  void _maybeRequest() {
    if (_pullInFlight ||
        _terminal ||
        _shutdown != null ||
        !_controller.hasListener ||
        _controller.isPaused) {
      return;
    }
    _pullInFlight = true;
    _onDemand();
  }

  /// Runs on explicit subscription cancel AND implicitly after the done
  /// event that [addEof]/[addFailure] deliver — hence the `_terminal` guard
  /// deciding whether this is an abort or ordinary cleanup.
  Future<void> _cancel() => _shutdown ??= _onShutdown(abort: !_terminal);

  /// A pull came back with a body chunk.
  void addChunk(Uint8List bytes) {
    _pullInFlight = false;
    if (_terminal || _shutdown != null) {
      // The result of a pull that was in flight when the consumer cancelled:
      // nobody is listening, drop it.
      return;
    }
    _controller.add(bytes);
    // If the consumer paused while the pull was in flight this requests
    // nothing — the chunk above is the single buffered overshoot.
    _maybeRequest();
  }

  /// A pull came back with end-of-body.
  void addEof() {
    _pullInFlight = false;
    if (_terminal || _shutdown != null) {
      return;
    }
    _terminal = true;
    _controller.close();
  }

  /// A pull came back with a terminal failure, or the pump itself died.
  void addFailure(VaneHttpException error) {
    _pullInFlight = false;
    if (_terminal || _shutdown != null) {
      // Typically the `Cancelled` error of the read the consumer's own
      // cancel interrupted; the consumer asked for that, so it is not news.
      return;
    }
    _terminal = true;
    _controller
      ..addError(error)
      ..close();
  }
}

/// Owns one stream's pump isolate: spawns it, decodes its messages into a
/// [StreamBodyController], and tears it down exactly once. One instance per
/// streaming request, alive for the stream's lifetime.
class _VaneStreamPump {
  _VaneStreamPump(
    this._bindings,
    DynamicLibrary library,
    int clientHandle,
    Map<String, Object?> request, {
    required this._cancelTokenId,
    required this._ownsCancelToken,
  }) {
    _responses.listen(_onMessage);
    Isolate.spawn(
      _pumpMain,
      (
        _responses.sendPort,
        library.lookup<NativeFunction<_ExecuteStreamingNative>>(
          'vane_ffi_execute_streaming',
        ),
        library.lookup<NativeFunction<_StreamReadNative>>(
          'vane_ffi_stream_read',
        ),
        library.lookup<NativeFunction<_StreamCloseNative>>(
          'vane_ffi_stream_close',
        ),
        library.lookup<NativeFunction<_BufferFreeNative>>(
          'vane_ffi_buffer_free',
        ),
        clientHandle,
        request,
      ),
      // Without these a pump that dies leaves the body stream (and any
      // cancel) waiting forever.
      onExit: _responses.sendPort,
      onError: _responses.sendPort,
    ).then((_) {}, onError: _onSpawnError);
    // No Isolate handle is kept: the pump is never killed from outside — it
    // exits by protocol ('close', or a failed header phase), and a blocked
    // read is interrupted through the cancel token, not by killing an
    // isolate mid-FFI-call.
  }

  final _VaneFfiBindings _bindings;
  final int _cancelTokenId;
  final bool _ownsCancelToken;
  final ReceivePort _responses = ReceivePort();
  final Completer<(int, int)> _head = Completer<(int, int)>();
  final Completer<void> _closed = Completer<void>();
  SendPort? _commands;
  StreamBodyController? _body;
  bool _finished = false;

  /// Completes with the decoded head once the header phase is done, wiring
  /// the body stream up on success and tearing the pump down on failure.
  Future<VaneStreamingResponse> start() async {
    final (address, streamHandle) = await _head.future;
    try {
      final head = _bindings.readResponse(address);
      if (streamHandle == 0) {
        // Unreachable by the ABI contract (success implies a handle);
        // refuse loudly rather than hand out a body that can never pump.
        throw const VaneHttpException(
          'Native Vane streaming returned no stream handle.',
        );
      }
      final body = StreamBodyController(
        onDemand: _requestRead,
        onShutdown: _shutdown,
      );
      _body = body;
      return VaneStreamingResponse(head: head, body: body.stream);
    } catch (error) {
      // The request failed at or before the headers: the pump exits on its
      // own (stream handle 0 ends it), which completes [_closed] via onExit;
      // waiting on that is what makes token release safe here.
      await _shutdown(abort: false);
      rethrow;
    }
  }

  void _requestRead() {
    _commands?.send('read');
  }

  Future<void> _shutdown({required bool abort}) {
    if (abort && _cancelTokenId != 0) {
      // Interrupt a pull blocked inside the native read; without this,
      // close would wait it out (H3 notices within its socket tick, TCP at
      // the next chunk or its inactivity budget — that bound is documented
      // on VaneStreamingResponse).
      _bindings.cancelToken(_cancelTokenId);
    }
    // Queues behind an in-flight read on the pump's mailbox, which is
    // exactly the serialization close needs. Dropped harmlessly if the pump
    // already exited; [_closed] then completes through onExit instead of
    // the 'closed' reply.
    _commands?.send('close');
    return _closed.future;
  }

  /// Exactly-once teardown of the Dart-side resources.
  void _finish() {
    if (_finished) {
      return;
    }
    _finished = true;
    _responses.close();
    if (_ownsCancelToken) {
      _bindings.freeCancelToken(_cancelTokenId);
    }
  }

  void _onSpawnError(Object error, StackTrace stackTrace) {
    _onMessage(<Object?>[error.toString(), stackTrace.toString()]);
  }

  void _onMessage(Object? message) {
    if (message == null || message is List) {
      // onExit sends null, onError sends [error, stackTrace]. For a pump
      // that exited by protocol ('closed', or a failed header phase) this
      // is routine cleanup; for one that died mid-stream it is the only
      // thing standing between the consumer and a stream that never ends.
      final error = VaneHttpException(
        message is List
            ? 'Vane stream pump isolate died: ${message.first}'
            : 'Vane stream pump isolate exited unexpectedly.',
      );
      if (!_head.isCompleted) {
        _head.completeError(
          error,
          message is List && message.length > 1
              ? StackTrace.fromString('${message[1]}')
              : StackTrace.empty,
        );
      }
      _body?.addFailure(error);
      if (!_closed.isCompleted) {
        _closed.complete();
      }
      _finish();
      return;
    }
    switch (message) {
      case 'closed':
        if (!_closed.isCompleted) {
          _closed.complete();
        }
        _finish();
      case 'eof':
        _body?.addEof();
      case (
        'head',
        final int address,
        final int streamHandle,
        final SendPort commands,
        final String? error,
        final String? stackTrace,
      ):
        _commands = commands;
        if (error != null) {
          _head.completeError(
            VaneHttpException(error),
            StackTrace.fromString(stackTrace ?? ''),
          );
        } else {
          _head.complete((address, streamHandle));
        }
      case ('chunk', final TransferableTypedData data):
        _body?.addChunk(data.materialize().asUint8List());
      case ('error', final String text, final int kind):
        _body?.addFailure(VaneHttpException(text, kind: _errorKind(kind)));
      default:
        // A message shape this build does not know cannot happen without a
        // bug in this file; dropping it beats crashing the app over it.
        assert(false, 'unknown Vane stream pump message: $message');
    }
  }

  /// Runs on the pump isolate. One stream, three phases: the blocking header
  /// call, then one blocking `vane_ffi_stream_read` per 'read' command, then
  /// `vane_ffi_stream_close` on 'close' and exit.
  ///
  /// The demand decision — when to send 'read' — lives entirely in
  /// [StreamBodyController] on the calling isolate. This side is
  /// deliberately incapable of running ahead: there is no loop here, only
  /// one reply per command.
  static void _pumpMain(
    (
      SendPort,
      Pointer<NativeFunction<_ExecuteStreamingNative>>,
      Pointer<NativeFunction<_StreamReadNative>>,
      Pointer<NativeFunction<_StreamCloseNative>>,
      Pointer<NativeFunction<_BufferFreeNative>>,
      int,
      Map<String, Object?>,
    )
    init,
  ) {
    final (
      responses,
      executePointer,
      readPointer,
      closePointer,
      freePointer,
      clientHandle,
      request,
    ) = init;
    final commands = ReceivePort();
    var address = 0;
    var streamHandle = 0;
    String? error;
    String? stackTrace;
    _NativeRequest? nativeRequest;
    final outStream = calloc<Uint64>();
    try {
      nativeRequest = _NativeRequest(request);
      final response = executePointer.asFunction<_ExecuteStreamingDart>()(
        clientHandle,
        nativeRequest.pointer,
        nativeRequest.body.pointer,
        nativeRequest.body.length,
        outStream,
      );
      address = response.address;
      streamHandle = outStream.value;
    } catch (caught, caughtStack) {
      // Strings only, like the worker: an unsendable error object thrown
      // while reporting a failure would kill the pump silently.
      error = caught.toString();
      stackTrace = caughtStack.toString();
    } finally {
      calloc.free(outStream);
      nativeRequest?.free();
    }
    responses.send((
      'head',
      address,
      streamHandle,
      commands.sendPort,
      error,
      stackTrace,
    ));
    if (streamHandle == 0) {
      // Failed at or before the headers: there is no stream to pump. The
      // isolate's exit is the calling side's cleanup signal.
      commands.close();
      return;
    }
    final read = readPointer.asFunction<_StreamReadDart>();
    final close = closePointer.asFunction<_StreamCloseDart>();
    final bufferFree = freePointer.asFunction<_BufferFreeDart>();
    commands.listen((Object? command) {
      if (command == 'close') {
        // Frees the native handle too; safe after EOF or an error.
        close(streamHandle);
        responses.send('closed');
        commands.close();
        return;
      }
      // 'read': one blocking pull. Everything inside the try, so a decode
      // failure reports as a stream error instead of killing the isolate.
      try {
        final chunk = read(streamHandle);
        final failure = chunk.error;
        if (failure.data != nullptr && failure.len > 0) {
          final text = utf8.decode(failure.data.asTypedList(failure.len));
          final kind = chunk.errorKind;
          bufferFree(chunk.error);
          bufferFree(chunk.body);
          responses.send(('error', text, kind));
        } else if (chunk.eof) {
          bufferFree(chunk.body);
          bufferFree(chunk.error);
          responses.send('eof');
        } else {
          final body = chunk.body;
          // One copy, native to Dart; the transfer to the calling isolate
          // is then free instead of a second copy.
          final bytes = TransferableTypedData.fromList(<Uint8List>[
            if (body.data != nullptr && body.len > 0)
              body.data.asTypedList(body.len)
            else
              Uint8List(0),
          ]);
          bufferFree(chunk.body);
          bufferFree(chunk.error);
          responses.send(('chunk', bytes));
        }
      } catch (caught) {
        responses.send(('error', caught.toString(), 0));
      }
    });
  }
}

/// The demand side of a streamed request body — [StreamBodyController]'s
/// mirror image, with the roles flipped: the app produces, the core
/// consumes, and the blocking native write is the backpressure.
///
/// The whole value of this class is one rule: the caller's source is PAUSED
/// from the instant a chunk arrives until the core acknowledges its write.
/// When the transport's send window is full the write parks, the ack never
/// comes, and the pause holds — so the app's own stream is what stalls, and
/// Dart-side buffering is bounded at the single chunk in flight. An eager
/// subscription here would look identical on a demo and buffer unboundedly
/// against a slow network — `test/vane_flutter_upload_pump_test.dart` is
/// written to fail if that regresses (it counts what the source produced
/// against acks, the write-direction twin of the response tests' pull
/// counts).
///
/// The other rule is teardown, where the deadlock risk lives: every terminal
/// path runs [_stop], which fires [_onFree] — the DIRECT native free from
/// this never-parked isolate. A writer blocked inside the native write is
/// released only by that free (or the core's own request-failure latch);
/// anything routed through the writer isolate's mailbox would queue behind
/// the very call it must interrupt, and cancel would hang forever.
///
/// Error routing, per the design: a write the core fails is NOT re-reported
/// from here — the execute result carries the same error and is
/// authoritative; this side just stops. Only a failure of the caller's own
/// source is recorded ([sourceError]) so the platform can surface it in
/// place of the synthetic `Cancelled` its abort induces.
///
/// Public only for the tests; everything else reaches uploads through
/// [FfiVaneFlutter]'s request maps.
@visibleForTesting
final class UploadStreamDriver {
  UploadStreamDriver({
    required Stream<Uint8List> source,
    required this._onWrite,
    required this._onFinish,
    required this._onFree,
  }) {
    _subscription = source.listen(
      _onChunk,
      onDone: _onSourceDone,
      onError: _onSourceError,
      cancelOnError: true,
    );
  }

  /// One blocking write on the writer isolate. Never called with one
  /// outstanding — the pause below is what guarantees it.
  final Future<void> Function(Uint8List chunk) _onWrite;

  /// One blocking finish on the writer isolate; only ever called with no
  /// write in flight (the source's done event cannot be delivered while the
  /// subscription is paused).
  final Future<void> Function() _onFinish;

  /// Frees the native stream id and retires the writer. Runs on EVERY
  /// terminal path exactly once: after a clean finish it merely drops the id
  /// (queued bytes still drain, per the core contract), before one it is the
  /// abort that fails the request and unparks a blocked writer. Must never
  /// wait on an in-flight write.
  final void Function() _onFree;

  late final StreamSubscription<Uint8List> _subscription;
  final Completer<void> _done = Completer<void>();
  bool _stopped = false;

  /// The caller's source stream failed; recorded before the abort fires so
  /// the platform's error path can already see it and report it instead of
  /// the `Cancelled` the abort induces on the request.
  Object? sourceError;
  StackTrace? sourceStackTrace;

  /// Completes — never with an error — once this side reached a terminal
  /// state: clean finish, stopped on a core-failed write, source
  /// error/abort, or [dispose].
  Future<void> get done => _done.future;

  void _onChunk(Uint8List chunk) {
    // Paused for the whole round trip; this line is the entire backpressure
    // story on the Dart side.
    _subscription.pause();
    _onWrite(chunk).then(
      (_) {
        if (!_stopped) {
          _subscription.resume();
        }
      },
      onError: (Object _) {
        // The core already failed the request (or the writer died); the
        // execute result tells that story. Stopping also frees, which is a
        // harmless second latch on an already-failed stream.
        _stop();
      },
    );
  }

  void _onSourceDone() {
    _onFinish().then((_) => _stop(), onError: (Object _) => _stop());
  }

  void _onSourceError(Object error, StackTrace stackTrace) {
    sourceError = error;
    sourceStackTrace = stackTrace;
    _stop();
  }

  /// Idempotent single teardown for every path. Synchronous through
  /// [_onFree] on purpose: dispose-while-parked must reach the native free
  /// without awaiting anything.
  void _stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _subscription.cancel();
    _onFree();
    _done.complete();
  }

  /// The platform's hook for "the request settled, whatever the source is
  /// doing": covers a server that answered before the source finished and a
  /// request that failed while the source sat idle between chunks. Safe (and
  /// a no-op) at any point after this side's own terminal.
  void dispose() => _stop();
}

/// Owns one upload's writer isolate — [_VaneStreamPump]'s mirror: this side
/// initiates every blocking call, one command in flight at a time (the
/// driver's pause guarantees it), so the isolate is structurally incapable
/// of accumulating a chunk backlog. The isolate exits on its own at every
/// terminal: after 'finished', after reporting a failure (the stream is
/// latched; nothing more can succeed), or on 'close'.
class _VaneUploadWriter {
  _VaneUploadWriter(DynamicLibrary library, int streamId) {
    _responses.listen(_onMessage);
    Isolate.spawn(
      _writerMain,
      (
        _responses.sendPort,
        library.lookup<NativeFunction<_BodyStreamWriteNative>>(
          'vane_ffi_body_stream_write',
        ),
        library.lookup<NativeFunction<_BodyStreamFinishNative>>(
          'vane_ffi_body_stream_finish',
        ),
        library.lookup<NativeFunction<_BufferFreeNative>>(
          'vane_ffi_buffer_free',
        ),
        streamId,
      ),
      // Without these a writer that dies leaves the in-flight write's future
      // pending forever, which would wedge the driver's pause.
      onExit: _responses.sendPort,
      onError: _responses.sendPort,
    ).then((_) {}, onError: _onSpawnError);
    // No Isolate handle is kept, same as the response pump: the writer exits
    // by protocol, and a blocked write is interrupted through the native
    // free, never by killing an isolate mid-FFI-call.
  }

  final ReceivePort _responses = ReceivePort();
  final Completer<SendPort> _commands = Completer<SendPort>();

  /// The single in-flight call's completer; the driver's discipline is what
  /// makes a single slot sufficient.
  Completer<void>? _pending;
  SendPort? _commandPort;
  bool _closeRequested = false;
  bool _dead = false;

  Future<void> write(Uint8List chunk) =>
      _send(('write', TransferableTypedData.fromList(<Uint8List>[chunk])));

  Future<void> finish() => _send('finish');

  /// Fire-and-forget retirement. Dropped silently if the writer already
  /// exited; queues harmlessly behind a parked write otherwise (the free
  /// that accompanies it is what releases that write). A close that lands
  /// before the isolate reported its port — a source that errors in its
  /// first microtask gets here — is deferred to the port's arrival, or the
  /// isolate would idle forever.
  void close() {
    _closeRequested = true;
    _commandPort?.send('close');
  }

  Future<void> _send(Object command) async {
    if (_dead) {
      throw const VaneHttpException('Vane upload writer isolate is gone.');
    }
    final commands = await _commands.future;
    final completer = Completer<void>();
    assert(_pending == null, 'upload writer called with a call outstanding');
    _pending = completer;
    commands.send(command);
    return completer.future;
  }

  void _onSpawnError(Object error, StackTrace stackTrace) {
    _die(
      VaneHttpException('Vane upload writer isolate failed to spawn: $error'),
      stackTrace,
    );
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _commandPort = message;
      if (_closeRequested) {
        // The driver tore down before the writer was even ready. A _send
        // racing this close loses harmlessly: its command lands on the
        // closed port and its completer goes unanswered, which is fine
        // because close() is only ever called from the driver's terminal
        // state — nothing behind that completer can act again.
        message.send('close');
      }
      _commands.complete(message);
      return;
    }
    if (message == null || message is List) {
      // onExit sends null, onError sends [error, stackTrace]. After a clean
      // 'finished'/'failed'/'close' exit there is no pending call and this
      // is routine cleanup; mid-write it is the only thing standing between
      // the driver and a pause that never lifts.
      _die(
        VaneHttpException(
          message is List
              ? 'Vane upload writer isolate died: ${message.first}'
              : 'Vane upload writer isolate exited.',
        ),
        message is List && message.length > 1
            ? StackTrace.fromString('${message[1]}')
            : null,
      );
      return;
    }
    final pending = _pending;
    _pending = null;
    switch (message) {
      case 'written' || 'finished':
        pending?.complete();
      case ('failed', final String text, final int kind):
        pending?.completeError(VaneHttpException(text, kind: _errorKind(kind)));
      default:
        assert(false, 'unknown Vane upload writer message: $message');
    }
  }

  void _die(Object error, [StackTrace? stackTrace]) {
    if (_dead) {
      return;
    }
    _dead = true;
    _responses.close();
    final pending = _pending;
    _pending = null;
    if (!_commands.isCompleted) {
      _commands.completeError(error, stackTrace);
      // A _send parked on the completer above consumes the error; without a
      // waiter, mark it handled so a failed spawn after teardown cannot
      // surface as an unhandled asynchronous error.
      _commands.future.ignore();
    }
    pending?.completeError(error, stackTrace);
  }

  /// Runs on the writer isolate: one blocking native call per command, one
  /// reply per call — deliberately incapable of running ahead, exactly like
  /// the response pump's read side. Exits at every terminal so the parent's
  /// onExit doubles as the cleanup signal.
  static void _writerMain(
    (
      SendPort,
      Pointer<NativeFunction<_BodyStreamWriteNative>>,
      Pointer<NativeFunction<_BodyStreamFinishNative>>,
      Pointer<NativeFunction<_BufferFreeNative>>,
      int,
    )
    init,
  ) {
    final (responses, writePointer, finishPointer, freePointer, streamId) =
        init;
    final write = writePointer.asFunction<_BodyStreamWriteDart>();
    final finish = finishPointer.asFunction<_BodyStreamFinishDart>();
    final bufferFree = freePointer.asFunction<_BufferFreeDart>();
    final commands = ReceivePort();
    responses.send(commands.sendPort);
    final outError = calloc<_VaneFfiBuffer>();

    /// Reads and frees the error buffer; empty means success, by the ABI
    /// contract (the buffer, not the kind, is the discriminator).
    String? takeError() {
      final error = outError.ref;
      if (error.data == nullptr || error.len == 0) {
        return null;
      }
      final text = utf8.decode(error.data.asTypedList(error.len));
      bufferFree(outError.ref);
      return text;
    }

    void exitNow() {
      calloc.free(outError);
      commands.close();
    }

    commands.listen((Object? command) {
      // Everything inside the try: an escaping error would kill the isolate
      // while the parent believes a call is in flight.
      try {
        switch (command) {
          case 'close':
            exitNow();
          case 'finish':
            final kind = finish(streamId, outError);
            final failure = takeError();
            responses.send(
              failure == null ? 'finished' : ('failed', failure, kind),
            );
            exitNow();
          case ('write', final TransferableTypedData data):
            final chunk = _NativeBytes(data.materialize().asUint8List());
            try {
              final kind = write(
                streamId,
                chunk.pointer,
                chunk.length,
                outError,
              );
              final failure = takeError();
              if (failure == null) {
                responses.send('written');
              } else {
                // Terminal: the stream (and its request) is latched; no
                // later call can succeed, so exit rather than linger.
                responses.send(('failed', failure, kind));
                exitNow();
              }
            } finally {
              chunk.free();
            }
          default:
            assert(false, 'unknown Vane upload writer command: $command');
        }
      } catch (caught) {
        // Strings only, like the worker and the pump: an unsendable error
        // object thrown while reporting a failure would kill the writer
        // silently.
        responses.send(('failed', caught.toString(), 0));
        exitNow();
      }
    });
  }
}

class _VaneFfiBindings {
  _VaneFfiBindings(DynamicLibrary library)
    : _clientCreate = library
          .lookupFunction<_ClientCreateNative, _ClientCreateDart>(
            'vane_ffi_client_create',
          ),
      _clientClose = library
          .lookupFunction<_ClientCloseNative, _ClientCloseDart>(
            'vane_ffi_client_close',
          ),
      _setCertificatePins = library
          .lookupFunction<_SetCertificatePinsNative, _SetCertificatePinsDart>(
            'vane_ffi_client_set_certificate_pins',
          ),
      // isLeaf: these are id-table lookups and deallocations — no callbacks
      // into Dart, no blocking work. vane_ffi_execute and the client calls
      // stay non-leaf because they can run for the whole request.
      _responseFree = library
          .lookupFunction<_ResponseFreeNative, _ResponseFreeDart>(
            'vane_ffi_response_free',
            isLeaf: true,
          ),
      // Same symbol again, as a finalizer: its `VaneFfiResponse*` argument is
      // ABI-compatible with NativeFinalizerFunction's `Pointer<Void>`.
      _responseFinalizer = library.lookup<NativeFinalizerFunction>(
        'vane_ffi_response_free',
      ),
      _bufferFree = library.lookupFunction<_BufferFreeNative, _BufferFreeDart>(
        'vane_ffi_buffer_free',
        isLeaf: true,
      ),
      _cancelTokenCreate = library
          .lookupFunction<_IdCreateNative, _IdCreateDart>(
            'vane_ffi_cancel_token_create',
            isLeaf: true,
          ),
      _cancelTokenCancel = library
          .lookupFunction<_IdActionNative, _IdActionDart>(
            'vane_ffi_cancel_token_cancel',
            isLeaf: true,
          ),
      _cancelTokenFree = library.lookupFunction<_IdActionNative, _IdActionDart>(
        'vane_ffi_cancel_token_free',
        isLeaf: true,
      ),
      _progressCreate = library.lookupFunction<_IdCreateNative, _IdCreateDart>(
        'vane_ffi_progress_create',
        isLeaf: true,
      ),
      _progressSnapshot = library
          .lookupFunction<_ProgressSnapshotNative, _ProgressSnapshotDart>(
            'vane_ffi_progress_snapshot',
            isLeaf: true,
          ),
      _progressFree = library.lookupFunction<_IdActionNative, _IdActionDart>(
        'vane_ffi_progress_free',
        isLeaf: true,
      ),
      // Same id-table dialect as the token and progress trios. Only create
      // and free are bound here: write and finish BLOCK (that blocking is
      // the upload backpressure), so they run on the writer isolate from raw
      // symbol pointers, never on this isolate.
      _bodyStreamCreate = library
          .lookupFunction<_BodyStreamCreateNative, _BodyStreamCreateDart>(
            'vane_ffi_body_stream_create',
            isLeaf: true,
          ),
      _bodyStreamFree = library.lookupFunction<_IdActionNative, _IdActionDart>(
        'vane_ffi_body_stream_free',
        isLeaf: true,
      );

  final _ClientCreateDart _clientCreate;
  final _ClientCloseDart _clientClose;
  final _SetCertificatePinsDart _setCertificatePins;
  final _ResponseFreeDart _responseFree;
  final Pointer<NativeFinalizerFunction> _responseFinalizer;
  final _BufferFreeDart _bufferFree;
  final _IdCreateDart _cancelTokenCreate;
  final _IdActionDart _cancelTokenCancel;
  final _IdActionDart _cancelTokenFree;
  final _IdCreateDart _progressCreate;
  final _ProgressSnapshotDart _progressSnapshot;
  final _IdActionDart _progressFree;
  final _BodyStreamCreateDart _bodyStreamCreate;
  final _IdActionDart _bodyStreamFree;

  int createClient(Map<String, Object?> configuration) {
    final config = _NativeConfig(configuration);
    final error = calloc<_VaneFfiBuffer>();
    // Written by the native side only when creation fails; calloc's zero is
    // `unknown`, so an unwritten value classifies the same as pre-v5.
    final errorKind = calloc<Uint32>();
    try {
      final handle = _clientCreate(config.pointer, error, errorKind);
      final message = _readString(error.ref);
      if (message.isNotEmpty) {
        _bufferFree(error.ref);
        // v5: the kind rides the out-param, so a config the core rejects
        // throws `invalidRequest` — parity with Swift/Kotlin's typed
        // VaneError instead of the old `kind: unknown`.
        throw VaneHttpException(message, kind: _errorKind(errorKind.value));
      }
      if (handle == 0) {
        throw const VaneHttpException('Native Vane client creation failed.');
      }
      return handle;
    } finally {
      calloc.free(errorKind);
      calloc.free(error);
      config.free();
    }
  }

  /// Decodes the response a worker handed back, taking ownership of it. Every
  /// exit frees the response exactly once: eagerly here, or — once the body
  /// view exists — through the finalizer when that view becomes unreachable.
  VaneResponse readResponse(int address) {
    final pointer = Pointer<_VaneFfiResponse>.fromAddress(address);
    if (pointer == nullptr) {
      throw const VaneHttpException('Native Vane request returned null.');
    }
    var owned = true;
    try {
      final response = pointer.ref;
      final error = _readString(response.error);
      if (error.isNotEmpty) {
        throw VaneHttpException(error, kind: _errorKind(response.errorKind));
      }
      final (headers, setCookie) = _readHeaders(response.headers);
      final bodyFilePath = _readString(response.bodyFilePath);
      final url = _readString(response.url);
      final buffer = response.body;
      final Uint8List body;
      if (buffer.data == nullptr || buffer.len == 0) {
        body = Uint8List(0);
      } else {
        // Zero-copy view over the native body. The token is the response
        // pointer, not the default (the data pointer), because the finalizer
        // frees the whole response.
        body = buffer.data.asTypedList(
          buffer.len,
          finalizer: _responseFinalizer,
          token: pointer.cast(),
        );
        owned = false;
      }
      return VaneResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: body,
        bodyFilePath: bodyFilePath,
        isSuccess: response.isSuccess,
        url: url,
        setCookie: setCookie,
        httpVersion: _httpVersion(response.httpVersion),
      );
    } finally {
      if (owned) {
        _responseFree(pointer);
      }
    }
  }

  void closeClient(int handle) {
    _clientClose(handle);
  }

  void setCertificatePins(int handle, String host, List<String> pins) {
    final nativeHost = _NativeString(host);
    final nativePins = _NativeStringArray(pins);
    final error = calloc<_VaneFfiBuffer>();
    final nativeHostValue = calloc<_VaneFfiString>();
    final nativeList = calloc<_VaneFfiStringList>();
    try {
      nativeHost.writeTo(nativeHostValue.ref);
      nativeList.ref.values = nativePins.pointer;
      nativeList.ref.len = nativePins.length;
      final ok = _setCertificatePins(
        handle,
        nativeHostValue.ref,
        nativeList.ref,
        error,
      );
      final message = _readString(error.ref);
      if (message.isNotEmpty) {
        _bufferFree(error.ref);
        throw VaneHttpException(message);
      }
      if (!ok) {
        throw const VaneHttpException(
          'Native Vane certificate pin update failed.',
        );
      }
    } finally {
      calloc.free(nativeList);
      calloc.free(nativeHostValue);
      calloc.free(error);
      nativePins.free();
      nativeHost.free();
    }
  }

  int createCancelToken() => _cancelTokenCreate();

  void cancelToken(int id) => _cancelTokenCancel(id);

  void freeCancelToken(int id) => _cancelTokenFree(id);

  int createProgress() => _progressCreate();

  /// Negative-means-none is the ABI dialect for the optional length, same as
  /// `timeout_seconds`.
  int createBodyStream(int? contentLength) => _bodyStreamCreate(contentLength ?? -1);

  /// Releases the id; before a clean finish this aborts the request AND
  /// unparks a writer blocked inside the native write — which is why it must
  /// always be called from this (never-parked) isolate, not sent through the
  /// writer isolate's mailbox.
  void freeBodyStream(int id) => _bodyStreamFree(id);

  VaneProgress progressSnapshot(int id) {
    final progress = _progressSnapshot(id);
    return VaneProgress(
      uploadSent: progress.uploadSent,
      uploadTotal: progress.uploadTotal,
      downloadReceived: progress.downloadReceived,
      downloadTotal: progress.downloadTotal,
      done: progress.done,
    );
  }

  void freeProgress(int id) => _progressFree(id);
}

/// Bodies above this are recorded as a content length only. The VM keeps
/// profile data for the life of the process, so a handful of large transfers
/// would otherwise pin tens of megabytes in a debug build.
const int _maxProfiledBodyBytes = 1 << 20;

/// Opens a DevTools Network profile for [request]. Only reached when profiling
/// is enabled, so none of this allocates on a normal request. Returns null in
/// product mode, where `package:http_profile` is tree-shaken away.
Future<HttpClientRequestProfile?> _startProfile(
  Map<String, Object?> request,
  String? baseUrl,
) async {
  HttpClientRequestProfile? profile;
  try {
    profile = HttpClientRequestProfile.profile(
      requestStartTime: DateTime.now(),
      requestMethod: request['method'] as String? ?? 'GET',
      requestUri: _profileUri(request, baseUrl),
    );
    if (profile == null) {
      return null;
    }
    final headers = _stringMap(request['headers']);
    if (headers.isNotEmpty) {
      profile.requestData.headersCommaValues = headers;
    }
    profile.requestData.followRedirects = request['followRedirects'] as bool?;
    final body = request['body'] as Uint8List?;
    if (body != null) {
      profile.requestData.contentLength = body.length;
      if (body.length <= _maxProfiledBodyBytes) {
        profile.requestData.bodySink.add(body);
      }
    }
    await profile.requestData.close();
    return profile;
  } catch (error) {
    // The profile is registered with the VM store as soon as it is created, so
    // close it out rather than orphaning it, and run the request unprofiled.
    await profile?.requestData.closeWithError(error.toString());
    return null;
  }
}

Future<void> _finishProfile(
  HttpClientRequestProfile profile,
  VaneResponse response,
  DateTime? responseTime,
) async {
  try {
    profile.responseData
      ..startTime = responseTime
      ..statusCode = response.statusCode
      ..contentLength = response.body.length;
    if (response.setCookie.isEmpty) {
      profile.responseData.headersCommaValues = response.headers;
    } else {
      // `response.headers` can never hold `set-cookie` (the core keeps it out
      // and `_readHeaders` routes it out), so the comma-values map would show
      // a login response with no Set-Cookie at all — the exact symptom the
      // field exists to remove. The list-valued map is the only one that can
      // carry repeats.
      profile.responseData.headersListValues = <String, List<String>>{
        for (final header in response.headers.entries)
          header.key: <String>[header.value],
        'set-cookie': response.setCookie,
      };
    }
    if (response.body.length <= _maxProfiledBodyBytes) {
      // The sink copies the bytes, which is the price of profiling; the
      // response itself keeps its zero-copy view.
      profile.responseData.bodySink.add(response.body);
    }
    await profile.responseData.close();
  } catch (error) {
    await profile.responseData.closeWithError(error.toString());
  }
}

/// Exposes the DevTools URL join for testing; [_startProfile] is its only
/// runtime caller.
@visibleForTesting
String profileRequestUri(Map<String, Object?> request, String? baseUrl) =>
    _profileUri(request, baseUrl);

/// Mirrors Rust's `base_url.join(url)` + query append so the Network tab shows
/// the URL that was actually requested. Falls back to the raw value rather than
/// letting a malformed URL break the request it is only trying to describe.
String _profileUri(Map<String, Object?> request, String? baseUrl) {
  final url = request['url'] as String? ?? '';
  try {
    var uri = Uri.parse(url);
    if (baseUrl != null && !uri.hasScheme) {
      uri = Uri.parse(baseUrl).resolveUri(uri);
    }
    final query = _stringMap(request['queryParams']);
    if (query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{...uri.queryParameters, ...query},
      );
    }
    return uri.toString();
  } on FormatException {
    return url;
  }
}

/// Splits the native header array into the single-valued map and the raw
/// `Set-Cookie` list.
///
/// The array is a list, not a map: the core appends one `("set-cookie", value)`
/// entry per cookie, so `set-cookie` is the one key that legitimately repeats.
/// Routing it out is mandatory — left in, N cookies collapse to one arbitrary
/// value with nothing to notice it by.
(Map<String, String>, List<String>) _readHeaders(_VaneFfiHeaderArray headers) {
  if (headers.data == nullptr || headers.len == 0) {
    return (const <String, String>{}, const <String>[]);
  }
  final map = <String, String>{};
  final setCookie = <String>[];
  for (var index = 0; index < headers.len; index += 1) {
    final header = (headers.data + index).ref;
    final key = _readString(header.key);
    if (key == 'set-cookie') {
      setCookie.add(_readString(header.value));
    } else {
      map[key] = _readString(header.value);
    }
  }
  return (map, setCookie);
}

/// Ordinals are the ABI contract with `VaneHttpVersion::ffi_code`, which starts
/// at 1. A core newer than this package reports a code we have no name for;
/// that is `null`, the same answer as "no exchange completed".
VaneHttpVersion? _httpVersion(int code) =>
    code >= 1 && code <= VaneHttpVersion.values.length
    ? VaneHttpVersion.values[code - 1]
    : null;

/// Ordinals are the ABI contract with `VaneError::ffi_kind`. A core newer than
/// this package reports a code we have no name for; that is not an error, it is
/// a kind we cannot act on.
VaneErrorKind _errorKind(int code) => code < VaneErrorKind.values.length
    ? VaneErrorKind.values[code]
    : VaneErrorKind.unknown;

String _readString(_VaneFfiBuffer buffer) {
  final bytes = _readBytes(buffer);
  if (bytes.isEmpty) {
    return '';
  }
  return utf8.decode(bytes);
}

Uint8List _readBytes(_VaneFfiBuffer buffer) {
  if (buffer.data == nullptr || buffer.len == 0) {
    return Uint8List(0);
  }
  return Uint8List.fromList(buffer.data.asTypedList(buffer.len));
}

class _NativeConfig {
  _NativeConfig(Map<String, Object?> config)
    : pointer = calloc<_VaneFfiClientConfig>(),
      baseUrl = _NativeString(config['baseUrl'] as String?),
      defaultHeaders = _NativeStringPairArray(
        _stringMap(config['defaultHeaders']),
      ),
      dnsOverrides = _NativeStringPairArray(_stringMap(config['dnsOverrides'])),
      certificatePins = _NativeStringListPairArray(
        _stringListMap(config['certificatePins']),
      ),
      cookiePersistencePath = _NativeString(
        config['cookiePersistencePath'] as String?,
      ),
      userAgent = _NativeString(config['userAgent'] as String?),
      proxyUrl = _NativeString(config['proxyUrl'] as String?),
      proxyAuthorization = _NativeString(
        config['proxyAuthorization'] as String?,
      ),
      // One concatenated bundle over the C ABI; PEM is concatenation-safe.
      customRootCaPem = _NativeString(
        _pemBundle(config['customRootCertificates']),
      ),
      clientCertificatePem = _NativeString(
        _nestedString(config['clientCertificate'], 'certificatePem'),
      ),
      clientPrivateKeyPem = _NativeString(
        _nestedString(config['clientCertificate'], 'privateKeyPem'),
      ) {
    final ref = pointer.ref;
    baseUrl.writeTo(ref.baseUrl);
    ref.defaultHeaders = defaultHeaders.pointer;
    ref.defaultHeadersLen = defaultHeaders.length;
    ref.dnsOverrides = dnsOverrides.pointer;
    ref.dnsOverridesLen = dnsOverrides.length;
    ref.certificatePins = certificatePins.pointer;
    ref.certificatePinsLen = certificatePins.length;
    ref.cookiesEnabled = config['cookiesEnabled'] as bool? ?? false;
    cookiePersistencePath.writeTo(ref.cookiePersistencePath);
    ref.connectionPoolEnabled =
        config['connectionPoolEnabled'] as bool? ?? true;
    ref.maxIdleConnections = config['maxIdleConnections'] as int? ?? 8;
    ref.connectionIdleTimeoutSeconds =
        config['connectionIdleTimeoutSeconds'] as int? ?? 30;
    ref.retryMaxAttempts = config['retryMaxAttempts'] as int? ?? 1;
    ref.retryInitialDelayMillis =
        config['retryInitialDelayMillis'] as int? ?? 100;
    ref.retryMaxDelayMillis = config['retryMaxDelayMillis'] as int? ?? 1000;
    ref.retryUnsafeMethods = config['retryUnsafeMethods'] as bool? ?? false;
    ref.maxRequestBodyBytes = config['maxRequestBodyBytes'] as int? ?? 10485760;
    ref.maxResponseBodyBytes =
        config['maxResponseBodyBytes'] as int? ?? 10485760;
    ref.timeoutSeconds = config['timeoutSeconds'] as int? ?? -1;
    ref.followRedirects = config['followRedirects'] as bool? ?? true;
    userAgent.writeTo(ref.userAgent);
    ref.protocolMode = _protocolMode(config['protocolMode'] as String?);
    proxyUrl.writeTo(ref.proxyUrl);
    proxyAuthorization.writeTo(ref.proxyAuthorization);
    ref.maxRedirects = config['maxRedirects'] as int? ?? 10;
    ref.tlsMinVersion = _tlsVersionByte(config['tlsMinVersion'] as String?);
    ref.tlsMaxVersion = _tlsVersionByte(config['tlsMaxVersion'] as String?);
    customRootCaPem.writeTo(ref.customRootCaPem);
    clientCertificatePem.writeTo(ref.clientCertificatePem);
    clientPrivateKeyPem.writeTo(ref.clientPrivateKeyPem);
  }

  final Pointer<_VaneFfiClientConfig> pointer;
  final _NativeString baseUrl;
  final _NativeStringPairArray defaultHeaders;
  final _NativeStringPairArray dnsOverrides;
  final _NativeStringListPairArray certificatePins;
  final _NativeString cookiePersistencePath;
  final _NativeString userAgent;
  final _NativeString proxyUrl;
  final _NativeString proxyAuthorization;
  final _NativeString customRootCaPem;
  final _NativeString clientCertificatePem;
  final _NativeString clientPrivateKeyPem;

  void free() {
    clientPrivateKeyPem.free();
    clientCertificatePem.free();
    customRootCaPem.free();
    proxyAuthorization.free();
    proxyUrl.free();
    userAgent.free();
    cookiePersistencePath.free();
    certificatePins.free();
    dnsOverrides.free();
    defaultHeaders.free();
    baseUrl.free();
    calloc.free(pointer);
  }
}

class _NativeRequest {
  _NativeRequest(Map<String, Object?> request)
    : pointer = calloc<_VaneFfiRequest>(),
      url = _NativeString(request['url'] as String? ?? ''),
      method = _NativeString(request['method'] as String? ?? 'GET'),
      headers = _NativeStringPairArray(_stringMap(request['headers'])),
      queryParams = _NativeStringPairArray(_stringMap(request['queryParams'])),
      bodyFilePath = _NativeString(request['bodyFilePath'] as String?),
      responseBodyPath = _NativeString(request['responseBodyPath'] as String?),
      body = _NativeBytes((request['body'] as Uint8List?) ?? Uint8List(0)) {
    final ref = pointer.ref;
    url.writeTo(ref.url);
    method.writeTo(ref.method);
    ref.headers = headers.pointer;
    ref.headersLen = headers.length;
    ref.queryParams = queryParams.pointer;
    ref.queryParamsLen = queryParams.length;
    bodyFilePath.writeTo(ref.bodyFilePath);
    responseBodyPath.writeTo(ref.responseBodyPath);
    ref.cancelTokenId = request['cancelTokenId'] as int? ?? 0;
    ref.progressId = request['progressId'] as int? ?? 0;
    ref.timeoutSeconds = request['timeoutSeconds'] as int? ?? -1;
    ref.followRedirects = request['followRedirects'] as bool? ?? true;
    ref.bodyStreamId = request['bodyStreamId'] as int? ?? 0;
  }

  final Pointer<_VaneFfiRequest> pointer;
  final _NativeString url;
  final _NativeString method;
  final _NativeStringPairArray headers;
  final _NativeStringPairArray queryParams;
  final _NativeString bodyFilePath;
  final _NativeString responseBodyPath;
  final _NativeBytes body;

  void free() {
    body.free();
    responseBodyPath.free();
    bodyFilePath.free();
    queryParams.free();
    headers.free();
    method.free();
    url.free();
    calloc.free(pointer);
  }
}

class _NativeStringPairArray {
  _NativeStringPairArray(Map<String, String> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiStringPair>(values.length) {
    var index = 0;
    for (final entry in values.entries) {
      final key = _NativeString(entry.key);
      final value = _NativeString(entry.value);
      strings
        ..add(key)
        ..add(value);
      key.writeTo(pointer[index].key);
      value.writeTo(pointer[index].value);
      index += 1;
    }
  }

  final Pointer<_VaneFfiStringPair> pointer;
  final int length;
  final List<_NativeString> strings = <_NativeString>[];

  void free() {
    for (final string in strings.reversed) {
      string.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeStringListPairArray {
  _NativeStringListPairArray(Map<String, List<String>> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiStringListPair>(values.length) {
    var index = 0;
    for (final entry in values.entries) {
      final key = _NativeString(entry.key);
      final list = _NativeStringArray(entry.value);
      keys.add(key);
      lists.add(list);
      key.writeTo(pointer[index].key);
      pointer[index].values.values = list.pointer;
      pointer[index].values.len = list.length;
      index += 1;
    }
  }

  final Pointer<_VaneFfiStringListPair> pointer;
  final int length;
  final List<_NativeString> keys = <_NativeString>[];
  final List<_NativeStringArray> lists = <_NativeStringArray>[];

  void free() {
    for (final list in lists.reversed) {
      list.free();
    }
    for (final key in keys.reversed) {
      key.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeStringArray {
  _NativeStringArray(List<String> values)
    : length = values.length,
      pointer = values.isEmpty
          ? nullptr
          : calloc<_VaneFfiString>(values.length) {
    for (var index = 0; index < values.length; index += 1) {
      final string = _NativeString(values[index]);
      strings.add(string);
      string.writeTo(pointer[index]);
    }
  }

  final Pointer<_VaneFfiString> pointer;
  final int length;
  final List<_NativeString> strings = <_NativeString>[];

  void free() {
    for (final string in strings.reversed) {
      string.free();
    }
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

class _NativeString {
  _NativeString(String? value)
    : bytes = _NativeBytes(
        value == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(value)),
      );

  final _NativeBytes bytes;

  void writeTo(_VaneFfiString target) {
    target.data = bytes.pointer;
    target.len = bytes.length;
  }

  void free() {
    bytes.free();
  }
}

class _NativeBytes {
  _NativeBytes(List<int> bytes)
    : length = bytes.length,
      pointer = bytes.isEmpty ? nullptr : calloc<Uint8>(bytes.length) {
    if (bytes.isNotEmpty) {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
    }
  }

  final Pointer<Uint8> pointer;
  final int length;

  void free() {
    if (pointer != nullptr) {
      calloc.free(pointer);
    }
  }
}

Map<String, String> _stringMap(Object? value) {
  final map = (value as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
  return map.map((key, value) => MapEntry(key.toString(), value.toString()));
}

Map<String, List<String>> _stringListMap(Object? value) {
  final map = (value as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
  return map.map((key, value) {
    final values = (value as List<Object?>?) ?? const <Object?>[];
    return MapEntry(
      key.toString(),
      values.map((item) => item.toString()).toList(),
    );
  });
}

/// Joins the PEM bundle list into the single string the C ABI carries; null
/// (an empty `customRootCaPem`) is how "no custom roots" crosses.
String? _pemBundle(Object? value) {
  final list = (value as List<Object?>?) ?? const <Object?>[];
  if (list.isEmpty) {
    return null;
  }
  return list.map((item) => item.toString()).join('\n');
}

String? _nestedString(Object? value, String key) {
  final map = value as Map<Object?, Object?>?;
  return map?[key] as String?;
}

/// Twin of the native `ffi_tls_version` decoder: 0 unset, 12, 13.
int _tlsVersionByte(String? value) {
  switch (value) {
    case null:
      return 0;
    case 'tls12':
      return 12;
    case 'tls13':
      return 13;
    default:
      throw VaneHttpException('Invalid Vane TLS version: $value');
  }
}

int _protocolMode(String? value) {
  switch (value) {
    case 'http3ThenHttp2ThenHttp1':
      return 0;
    case 'http3Only':
    case null:
      return 1;
    case 'http2ThenHttp1':
      return 2;
    case 'http2Only':
      return 3;
    case 'http1Only':
      return 4;
    default:
      throw VaneHttpException('Invalid Vane protocol mode: $value');
  }
}
