import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'vane_flutter.dart';
import 'vane_flutter_ffi.dart';

abstract class VaneFlutterPlatform extends PlatformInterface {
  VaneFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static VaneFlutterPlatform _instance = FfiVaneFlutter();

  static VaneFlutterPlatform get instance => _instance;

  static set instance(VaneFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<int> createClient(Map<String, Object?> configuration) {
    throw UnimplementedError('createClient() has not been implemented.');
  }

  Future<VaneResponse> execute(int handle, Map<String, Object?> request) {
    throw UnimplementedError('execute() has not been implemented.');
  }

  /// Executes [request], resolving at the final response's headers with the
  /// body left to stream; see `VaneClient.executeStreaming`.
  ///
  /// Only the FFI platform implements this. The MethodChannel fallback
  /// deliberately does not: streaming's backpressure contract — one native
  /// pull per unit of listener demand — cannot be expressed over a
  /// request/response channel without an EventChannel protocol plus an
  /// ack-per-chunk scheme, and every supported platform already gets the
  /// FFI implementation by default. On the fallback, use [execute]'s
  /// buffered response instead.
  Future<VaneStreamingResponse> executeStreaming(
    int handle,
    Map<String, Object?> request,
  ) {
    throw UnimplementedError('executeStreaming() has not been implemented.');
  }

  Future<void> closeClient(int handle) {
    throw UnimplementedError('closeClient() has not been implemented.');
  }

  Future<void> setCertificatePins(int handle, String host, List<String> pins) {
    throw UnimplementedError('setCertificatePins() has not been implemented.');
  }

  /// Installs (null clears) the caller-supplied DNS resolver; see
  /// `VaneClient.setDnsResolver`. Only the FFI platform implements this —
  /// like [executeStreaming], a per-lookup native callback cannot be
  /// expressed over a request/response method channel.
  Future<void> setDnsResolver(int handle, VaneDnsResolver? resolver) {
    throw UnimplementedError('setDnsResolver() has not been implemented.');
  }

  /// Best-effort warm-up of the client behind [handle]; see
  /// `VaneClient.warmup`. Defaults to a no-op rather than
  /// [UnimplementedError]: warmup is a performance affordance whose failures
  /// are swallowed by contract, so a platform that has not implemented it
  /// must degrade to "not warmed", never crash an app's startup path.
  Future<void> warmup(int handle, String? url) async {}

  Future<int> createCancelToken() {
    throw UnimplementedError('createCancelToken() has not been implemented.');
  }

  Future<void> cancelToken(int id) {
    throw UnimplementedError('cancelToken() has not been implemented.');
  }

  Future<void> freeCancelToken(int id) {
    throw UnimplementedError('freeCancelToken() has not been implemented.');
  }

  Future<int> createProgress() {
    throw UnimplementedError('createProgress() has not been implemented.');
  }

  Future<VaneProgress> progressSnapshot(int id) {
    throw UnimplementedError('progressSnapshot() has not been implemented.');
  }

  Future<void> freeProgress(int id) {
    throw UnimplementedError('freeProgress() has not been implemented.');
  }
}
