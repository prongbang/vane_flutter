import 'dart:async';

import 'package:http/http.dart' as http;

import 'vane_flutter.dart';

/// A `package:http` [http.Client] backed by Vane's HTTP/3 core, so the pub.dev
/// ecosystem (and anything else written against `package:http`) can use Vane as
/// its transport.
///
/// ```dart
/// final client = VaneHttpClient();
/// final response = await client.get(Uri.parse('https://example.com/'));
/// client.close();
/// ```
///
/// Requests made through this client appear in the DevTools Network tab like
/// any other Vane request — profiling is recorded in the platform layer, not
/// here.
///
/// Known ceilings, all inherited from the core rather than introduced here:
/// - The core returns a complete response body, so [send] yields it as a single
///   chunk. Real chunked streaming needs an incremental read on the Rust side.
/// - Response headers are single-valued: the core comma-joins repeated ones
///   into one `', '`-separated value (identically on both transports), which
///   [http.BaseResponse.headersSplitValues] splits back apart. `set-cookie` is
///   the exception and is handled below.
/// - `set-cookie` is comma-joined into [http.BaseResponse.headers], which is
///   what `package:http`'s own `IOClient` does — multiple cookies are ambiguous
///   there by `package:http`'s design, not Vane's. Splitting the joined value
///   on `,` is wrong: an `Expires` attribute contains one. Use
///   [http.BaseResponse.headersSplitValues], whose `set-cookie` splitter
///   accounts for that, or [VaneResponse.setCookie] for the lossless list.
/// - Those `set-cookie` values are raw and unfiltered — a cookie Vane's own
///   jar refused (a `Domain` that is a public suffix, or an IP literal) still
///   appears among them. Feeding them straight into a third-party cookie store
///   re-admits what Vane deliberately rejected.
/// - The negotiated protocol ([VaneResponse.httpVersion]) is not exposed:
///   [http.BaseResponse] has no field for it. Use [VaneClient] directly, or the
///   dio adapter, which puts it in `Response.extra`.
/// - The FFI response carries no reason phrase and no redirect chain, so
///   [http.StreamedResponse.reasonPhrase] and `isRedirect` are left unset and
///   [http.BaseRequest.maxRedirects] is ignored.
///   [http.BaseRequest.followRedirects] is honored.
/// - [http.BaseRequest.persistentConnection] is ignored: connection reuse is a
///   client-wide Vane setting, not a per-request one.
///
/// [http.Abortable.abortTrigger] is honored: it is wired to a Vane cancel
/// token and surfaces as [http.RequestAbortedException]. An abort landing
/// before the token has registered with the core is latched and replayed at
/// registration, so the native request is stopped rather than run to
/// completion.
class VaneHttpClient extends http.BaseClient {
  /// Creates an adapter. Pass [client] to share an existing [VaneClient] — its
  /// configuration, interceptors and connection pool — in which case [close]
  /// leaves it open. Without one, a private [VaneClient] is created and closed
  /// together with this adapter.
  VaneHttpClient({VaneClient? client})
    : _client = client ?? VaneClient(),
      _ownsClient = client == null;

  final VaneClient _client;
  final bool _ownsClient;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      _throwClosed(request.url);
    }

    // `abortTrigger` is the one part of the http contract Vane can honour
    // rather than inherit a gap on: it maps onto a cancel token.
    final abortTrigger = request is http.Abortable
        ? request.abortTrigger
        : null;
    VaneCancelToken? token;
    var aborted = false;
    if (abortTrigger != null) {
      final cancelToken = token = VaneCancelToken();
      unawaited(
        abortTrigger
            .then((_) {
              aborted = true;
              return cancelToken.cancel();
            })
            .catchError((Object _) {}),
      );
    }

    try {
      final body = await request.finalize().toBytes();
      // close() can land while the body is being finalized; without this the
      // request would go on to open a fresh native client.
      if (_closed) {
        _throwClosed(request.url);
      }
      if (aborted) {
        throw http.RequestAbortedException(request.url);
      }

      final builder = _client
          .request(request.url.toString(), method: request.method)
          .headers(request.headers)
          .followRedirects(request.followRedirects);
      if (body.isNotEmpty) {
        builder.body(body);
      }
      if (token != null) {
        builder.cancelToken(token);
      }

      final VaneResponse response;
      try {
        response = await builder.execute();
      } on VaneHttpException catch (error) {
        // Trust the flag rather than the core's error text.
        if (aborted) {
          throw http.RequestAbortedException(request.url);
        }
        throw http.ClientException(error.message, request.url);
      }
      if (aborted) {
        throw http.RequestAbortedException(request.url);
      }
      // A status the core could not parse arrives as 0, which BaseResponse
      // rejects with a raw ArgumentError.
      if (response.statusCode < 100) {
        throw http.ClientException(
          'Invalid status code ${response.statusCode}.',
          request.url,
        );
      }

      return http.StreamedResponse(
        // Single chunk over the zero-copy body view: no copy happens until the
        // caller collects the stream.
        Stream<List<int>>.value(response.body),
        response.statusCode,
        contentLength: response.body.length,
        request: request,
        headers: response.setCookie.isEmpty
            ? response.headers
            // A new map: the FFI one may be const. Comma-joined because
            // BaseResponse.headers is Map<String, String> — the same lossy
            // thing package:http's own IOClient does.
            : <String, String>{
                ...response.headers,
                'set-cookie': response.setCookie.join(','),
              },
      );
    } finally {
      await token?.dispose();
    }
  }

  Never _throwClosed(Uri url) {
    throw http.ClientException(
      'HTTP request failed. Client is already closed.',
      url,
    );
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_ownsClient) {
      // http's Client.close() is synchronous; the native handle is released in
      // the background, and a failure there must not become an unhandled error.
      unawaited(_client.close().catchError((Object _) {}));
    }
  }
}
