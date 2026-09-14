// The drive console is the spike's output channel.
// ignore_for_file: avoid_print

import 'package:cronet_http/cronet_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:vane_flutter/vane_flutter.dart';
import 'package:vane_flutter/vane_flutter_platform_interface.dart';

// ponytail: GET-only, buffered, no config — measures the platform swap and nothing else.
class _SpikeCronetPlatform extends VaneFlutterPlatform {
  _SpikeCronetPlatform(this._client);

  final CronetClient _client;

  @override
  Future<int> createClient(Map<String, Object?> configuration) async => 1;

  @override
  Future<void> closeClient(int handle) async {}

  @override
  Future<VaneResponse> execute(int handle, Map<String, Object?> request) async {
    final url = request['url']! as String;
    final outgoing = http.Request(request['method']! as String, Uri.parse(url))
      ..headers.addAll((request['headers']! as Map).cast<String, String>());
    final response = await _client.send(outgoing);
    final body = await response.stream.toBytes();
    return VaneResponse(
      statusCode: response.statusCode,
      headers: [
        for (final entry in response.headers.entries)
          (entry.key.toLowerCase(), entry.value),
      ],
      body: body,
      isSuccess: response.statusCode >= 200 && response.statusCode < 300,
      url: url,
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cronet_http spike', (tester) async {
    const url = String.fromEnvironment(
      'VANE_BENCH_URL',
      defaultValue: 'https://cloudflare-quic.com/',
    );
    const rounds = int.fromEnvironment('VANE_BENCH_ROUNDS', defaultValue: 6);
    const perRound = int.fromEnvironment('VANE_BENCH_REQUESTS', defaultValue: 10);
    final uri = Uri.parse(url);

    CronetClient cronet() => CronetClient.fromCronetEngine(
      CronetEngine.build(
        enableQuic: true,
        enableHttp2: true,
        quicHints: [(uri.host, 443, 443)],
      ),
      closeEngine: true,
    );

    final raw = cronet();
    final viaPlatform = cronet();
    final vaneCronet = VaneClient(platform: _SpikeCronetPlatform(viaPlatform));
    final vaneFfi = VaneClient(
      configuration: const VaneConfiguration(
        protocolMode: VaneProtocolMode.http3Only,
      ),
    );

    final contenders = <(String, Future<void> Function())>[
      ('raw-cronet_http', () async => await raw.get(uri)),
      ('vane-over-cronet_http', () async => await vaneCronet.get(url)),
      ('vane-ffi', () async => await vaneFfi.get(url)),
    ];
    final samples = {for (final c in contenders) c.$1: <double>[]};

    for (var i = 0; i < 5; i++) {
      for (final c in contenders) {
        await c.$2();
      }
    }
    for (var round = 0; round < rounds; round++) {
      for (var i = 0; i < contenders.length; i++) {
        final c = contenders[(i + round) % contenders.length];
        for (var n = 0; n < perRound; n++) {
          final stopwatch = Stopwatch()..start();
          await c.$2();
          samples[c.$1]!.add(stopwatch.elapsedMicroseconds / 1000);
        }
      }
    }

    double p50(List<double> v) => (List.of(v)..sort())[v.length ~/ 2];
    final m = {for (final e in samples.entries) e.key: p50(e.value)};
    m.forEach(
      (name, ms) => print('CRONETSPIKE p50 $name ${ms.toStringAsFixed(1)} ms'),
    );
    print(
      'CRONETSPIKE F1 ${(m['vane-over-cronet_http']! - m['raw-cronet_http']!).toStringAsFixed(1)} ms',
    );
    print(
      'CRONETSPIKE F2 ${(m['vane-ffi']! - m['vane-over-cronet_http']!).toStringAsFixed(1)} ms',
    );

    raw.close();
    await vaneCronet.close();
    await vaneFfi.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
