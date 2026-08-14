import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vane_flutter.dart';
import 'vane_flutter_platform_interface.dart';

/// Channel-based fallback for a host that embeds the core natively instead
/// of exposing the C ABI. Buffered requests only: `executeStreaming` is
/// deliberately not implemented here — a demand-driven body cannot ride a
/// request/response channel (see `VaneFlutterPlatform.executeStreaming`) —
/// so it throws [UnimplementedError] from the base class.
class MethodChannelVaneFlutter extends VaneFlutterPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('vane_flutter');

  @override
  Future<int> createClient(Map<String, Object?> configuration) async {
    final handle = await methodChannel.invokeMethod<int>(
      'createClient',
      <String, Object?>{'configuration': configuration},
    );
    if (handle == null) {
      throw StateError('Native Vane client creation returned no handle.');
    }
    return handle;
  }

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    final response = await methodChannel.invokeMethod<Map<Object?, Object?>>(
      'execute',
      <String, Object?>{'handle': handle, 'request': request},
    );
    if (response == null) {
      throw StateError('Native Vane request returned no response.');
    }
    return VaneResponse.fromMap(response);
  }

  @override
  Future<void> closeClient(int handle) async {
    await methodChannel.invokeMethod<void>('closeClient', <String, Object?>{
      'handle': handle,
    });
  }

  @override
  Future<void> setCertificatePins(
    int handle,
    String host,
    List<String> pins,
  ) async {
    await methodChannel.invokeMethod<void>(
      'setCertificatePins',
      <String, Object?>{'handle': handle, 'host': host, 'pins': pins},
    );
  }
}
