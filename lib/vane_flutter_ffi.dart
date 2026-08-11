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

typedef _ClientCreateNative =
    Uint64 Function(Pointer<_VaneFfiClientConfig>, Pointer<_VaneFfiBuffer>);
typedef _ClientCreateDart =
    int Function(Pointer<_VaneFfiClientConfig>, Pointer<_VaneFfiBuffer>);
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

/// The C ABI version this package's structs and calls were written against.
/// Rust exports the native side as `vane_ffi_abi_version`; the two must match
/// exactly, because every `_VaneFfi*` struct here mirrors its Rust layout by
/// hand and a skewed layout reads garbage — or frees wild pointers —
/// silently. Bump in lockstep with the Rust constant.
///
/// v2: `vane_ffi_client_warmup` — this package binds the symbol, so a v1
/// library cannot serve it and must be rejected with the clear version
/// message rather than a symbol-lookup failure.
const int _expectedAbiVersion = 2;

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
    } catch (error) {
      if (profile != null) {
        try {
          await profile.responseData.closeWithError(error.toString());
        } catch (_) {
          // Never let a recording failure mask the real error.
        }
      }
      rethrow;
    }
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

  int createClient(Map<String, Object?> configuration) {
    final config = _NativeConfig(configuration);
    final error = calloc<_VaneFfiBuffer>();
    try {
      final handle = _clientCreate(config.pointer, error);
      final message = _readString(error.ref);
      if (message.isNotEmpty) {
        _bufferFree(error.ref);
        throw VaneHttpException(message);
      }
      if (handle == 0) {
        throw const VaneHttpException('Native Vane client creation failed.');
      }
      return handle;
    } finally {
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

  void free() {
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
