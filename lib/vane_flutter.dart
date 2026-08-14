// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'vane_flutter_platform_interface.dart';

export 'vane_flutter_http.dart' show VaneHttpClient;

enum VaneProtocolMode {
  http3ThenHttp2ThenHttp1,
  http3Only,
  http2ThenHttp1,
  http2Only,
  http1Only,
}

extension VaneProtocolModeName on VaneProtocolMode {
  String get wireName {
    switch (this) {
      case VaneProtocolMode.http3ThenHttp2ThenHttp1:
        return 'http3ThenHttp2ThenHttp1';
      case VaneProtocolMode.http3Only:
        return 'http3Only';
      case VaneProtocolMode.http2ThenHttp1:
        return 'http2ThenHttp1';
      case VaneProtocolMode.http2Only:
        return 'http2Only';
      case VaneProtocolMode.http1Only:
        return 'http1Only';
    }
  }
}

class VaneConfiguration {
  const VaneConfiguration({
    this.baseUrl,
    this.defaultHeaders = const <String, String>{},
    this.dnsOverrides = const <String, String>{},
    this.certificatePins = const <String, List<String>>{},
    this.cookiesEnabled = false,
    this.cookiePersistencePath,
    this.connectionPoolEnabled = true,
    this.maxIdleConnections = 8,
    this.connectionIdleTimeoutSeconds = 30,
    this.retryMaxAttempts = 1,
    this.retryInitialDelayMillis = 100,
    this.retryMaxDelayMillis = 1000,
    this.retryUnsafeMethods = false,
    this.maxRequestBodyBytes = 10485760,
    this.maxResponseBodyBytes = 10485760,
    this.timeoutSeconds,
    this.followRedirects = true,
    this.userAgent,
    this.protocolMode = VaneProtocolMode.http3Only,
    this.proxyUrl,
    this.proxyAuthorization,
  });

  final String? baseUrl;
  final Map<String, String> defaultHeaders;
  final Map<String, String> dnsOverrides;
  final Map<String, List<String>> certificatePins;
  final bool cookiesEnabled;
  final String? cookiePersistencePath;
  final bool connectionPoolEnabled;
  final int maxIdleConnections;
  final int connectionIdleTimeoutSeconds;
  final int retryMaxAttempts;
  final int retryInitialDelayMillis;
  final int retryMaxDelayMillis;
  final bool retryUnsafeMethods;
  final int maxRequestBodyBytes;
  final int maxResponseBodyBytes;
  final int? timeoutSeconds;
  final bool followRedirects;
  final String? userAgent;
  final VaneProtocolMode protocolMode;
  final String? proxyUrl;
  final String? proxyAuthorization;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'baseUrl': baseUrl,
      'defaultHeaders': defaultHeaders,
      'dnsOverrides': dnsOverrides,
      'certificatePins': certificatePins,
      'cookiesEnabled': cookiesEnabled,
      'cookiePersistencePath': cookiePersistencePath,
      'connectionPoolEnabled': connectionPoolEnabled,
      'maxIdleConnections': maxIdleConnections,
      'connectionIdleTimeoutSeconds': connectionIdleTimeoutSeconds,
      'retryMaxAttempts': retryMaxAttempts,
      'retryInitialDelayMillis': retryInitialDelayMillis,
      'retryMaxDelayMillis': retryMaxDelayMillis,
      'retryUnsafeMethods': retryUnsafeMethods,
      'maxRequestBodyBytes': maxRequestBodyBytes,
      'maxResponseBodyBytes': maxResponseBodyBytes,
      'timeoutSeconds': timeoutSeconds,
      'followRedirects': followRedirects,
      'userAgent': userAgent,
      'protocolMode': protocolMode.wireName,
      'proxyUrl': proxyUrl,
      'proxyAuthorization': proxyAuthorization,
    };
  }
}

class VaneRequest {
  const VaneRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.body,
    this.bodyFilePath,
    this.responseBodyPath,
    this.cancelToken,
    this.onUploadProgress,
    this.onDownloadProgress,
    this.timeoutSeconds,
    this.followRedirects = true,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final Uint8List? body;
  final String? bodyFilePath;
  final String? responseBodyPath;
  final VaneCancelToken? cancelToken;
  final VaneProgressCallback? onUploadProgress;
  final VaneProgressCallback? onDownloadProgress;
  final int? timeoutSeconds;
  final bool followRedirects;

  VaneRequest copyWith({
    String? url,
    String? method,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    Uint8List? body,
    String? bodyFilePath,
    String? responseBodyPath,
    VaneCancelToken? cancelToken,
    VaneProgressCallback? onUploadProgress,
    VaneProgressCallback? onDownloadProgress,
    int? timeoutSeconds,
    bool? followRedirects,
  }) {
    return VaneRequest(
      url: url ?? this.url,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      queryParams: queryParams ?? this.queryParams,
      body: body ?? this.body,
      bodyFilePath: bodyFilePath ?? this.bodyFilePath,
      responseBodyPath: responseBodyPath ?? this.responseBodyPath,
      cancelToken: cancelToken ?? this.cancelToken,
      onUploadProgress: onUploadProgress ?? this.onUploadProgress,
      onDownloadProgress: onDownloadProgress ?? this.onDownloadProgress,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      followRedirects: followRedirects ?? this.followRedirects,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'url': url,
      'method': method,
      'headers': headers,
      'queryParams': queryParams,
      'body': body,
      'bodyFilePath': bodyFilePath,
      'responseBodyPath': responseBodyPath,
      'cancelTokenId': cancelToken?._id,
      'progressId': null,
      'timeoutSeconds': timeoutSeconds,
      'followRedirects': followRedirects,
    };
  }
}

class VaneResponse {
  const VaneResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.bodyFilePath,
    required this.isSuccess,
    required this.url,
    this.setCookie = const <String>[],
    this.httpVersion,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final String? bodyFilePath;
  final bool isSuccess;
  final String url;

  /// Raw `Set-Cookie` values from the final response, in wire order.
  ///
  /// Unfiltered: a cookie Vane's own jar refused still appears here, because
  /// this reports what the server sent. Never present in [headers] — a
  /// `Map<String, String>` cannot hold repeats and `Set-Cookie` values contain
  /// commas, so they cannot be joined losslessly.
  final List<String> setCookie;

  /// Protocol that served the final response, or `null` when no exchange
  /// completed or the transport could not say.
  final VaneHttpVersion? httpVersion;

  String get text => utf8.decode(body, allowMalformed: true);

  T json<T>() => jsonDecode(text) as T;

  VaneResponse validateStatus([int min = 200, int max = 299]) {
    if (statusCode < min || statusCode > max) {
      throw VaneHttpException(
        'Request failed with status $statusCode',
        statusCode: statusCode,
        response: this,
      );
    }
    return this;
  }

  static VaneResponse fromMap(Map<Object?, Object?> map) {
    final rawHeaders = (map['headers'] as Map<Object?, Object?>?) ?? const {};
    return VaneResponse(
      statusCode: (map['statusCode'] as num).toInt(),
      headers: rawHeaders.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      body: Uint8List.fromList((map['body'] as Uint8List?) ?? Uint8List(0)),
      bodyFilePath: map['bodyFilePath'] as String?,
      isSuccess: map['isSuccess'] as bool? ?? false,
      url: map['url'] as String? ?? '',
      // Read defensively: an older plugin sends neither key, and the defaults
      // are exactly what it used to mean.
      setCookie:
          (map['setCookie'] as List<Object?>?)
              ?.map((value) => value.toString())
              .toList(growable: false) ??
          const <String>[],
      httpVersion: VaneHttpVersion.values
          .where((version) => version.name == map['httpVersion'])
          .firstOrNull,
    );
  }
}

/// A response whose headers have arrived and whose body is still streaming.
///
/// [head] is the familiar [VaneResponse] — status, headers, final URL,
/// cookies, negotiated protocol — with [VaneResponse.body] empty by contract:
/// [body] delivers it instead.
///
/// [body] is single-subscription and demand-driven: chunks are pulled off the
/// native transport only as the listener consumes them, so pausing the
/// subscription stalls the sender through QUIC/TCP flow control instead of
/// buffering without bound (overshoot is bounded at the one pull already in
/// flight). Chunk boundaries carry no meaning. A failure after the headers
/// surfaces as an error on this stream, not as a failed request. Cancelling
/// the subscription aborts the transfer and discards the connection; the
/// cancel future completes once the native side has let go, which on a
/// silent TCP stream can take up to the read-inactivity budget.
///
/// Always listen to (or cancel) [body]: an abandoned, never-listened body
/// keeps its connection and its pump isolate until the process ends.
class VaneStreamingResponse {
  const VaneStreamingResponse({required this.head, required this.body});

  final VaneResponse head;
  final Stream<Uint8List> body;
}

/// Protocol a response was actually served over, as opposed to the
/// [VaneProtocolMode] the request asked for.
///
/// The ordinals are the ABI: they mirror `VaneHttpVersion::ffi_code` in the
/// Rust core (offset by one, since 0 there means "not known" and is `null`
/// here) and arrive in `VaneFfiResponse.http_version`. Append only, never
/// reorder. A code this build does not know decodes as `null`.
enum VaneHttpVersion { http10, http11, http2, http3 }

/// Machine-readable classification of a [VaneHttpException], so callers never
/// have to match on the core's English error text.
///
/// The ordinals are the ABI: they mirror `VaneError::ffi_kind` in the Rust core
/// and arrive in `VaneFfiResponse.error_kind`. Append only, never reorder. A
/// code this build does not know decodes as [unknown], which is also what
/// errors raised on the Dart side of the boundary carry.
enum VaneErrorKind {
  unknown,

  /// The request or client configuration is wrong — URL, scheme, method,
  /// header, body file, pin or proxy setting. Retrying changes nothing.
  invalidRequest,

  /// The request's cancel token was set.
  cancelled,

  /// The connection was not established within the deadline.
  connectTimeout,

  /// The deadline expired with the connection already up.
  timeout,

  /// Network or protocol failure: DNS, socket, QUIC, HTTP/3 framing, proxy.
  transport,

  /// Certificate verification failed, including a pin mismatch.
  tls,

  /// A request or response body exceeded the configured limit.
  bodyLimitExceeded,

  /// The requested protocol is not available in this build of the core.
  protocolUnsupported,
}

class VaneHttpException implements Exception {
  const VaneHttpException(
    this.message, {
    this.kind = VaneErrorKind.unknown,
    this.statusCode,
    this.response,
  });

  final String message;

  /// What went wrong, independent of [message]. [VaneErrorKind.unknown] means
  /// the core did not classify it, not that it was not a network failure.
  final VaneErrorKind kind;
  final int? statusCode;
  final VaneResponse? response;

  @override
  String toString() => 'VaneHttpException: $message';
}

typedef VaneRequestInterceptor = FutureOr<VaneRequest> Function(VaneRequest);
typedef VaneResponseInterceptor = FutureOr<VaneResponse> Function(VaneResponse);
typedef VaneErrorInterceptor =
    FutureOr<VaneResponse?> Function(Object, StackTrace);
typedef VaneProgressCallback = void Function(int transferred, int total);

class VaneRequestOptions {
  const VaneRequestOptions({
    this.headers = const <String, String>{},
    this.queryParams = const <String, String>{},
    this.timeoutSeconds,
    this.followRedirects,
    this.cancelToken,
    this.onUploadProgress,
    this.onDownloadProgress,
    this.responseBodyPath,
  });

  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final int? timeoutSeconds;
  final bool? followRedirects;
  final VaneCancelToken? cancelToken;
  final VaneProgressCallback? onUploadProgress;
  final VaneProgressCallback? onDownloadProgress;
  final String? responseBodyPath;

  VaneRequestBuilder applyTo(VaneRequestBuilder builder) {
    if (headers.isNotEmpty) {
      builder.headers(headers);
    }
    if (queryParams.isNotEmpty) {
      builder.queryParams(queryParams);
    }
    final timeout = timeoutSeconds;
    if (timeout != null) {
      builder.timeout(timeout);
    }
    final redirects = followRedirects;
    if (redirects != null) {
      builder.followRedirects(redirects);
    }
    final token = cancelToken;
    if (token != null) {
      builder.cancelToken(token);
    }
    final upload = onUploadProgress;
    if (upload != null) {
      builder.onUploadProgress(upload);
    }
    final download = onDownloadProgress;
    if (download != null) {
      builder.onDownloadProgress(download);
    }
    final outputPath = responseBodyPath;
    if (outputPath != null) {
      builder.downloadToFile(outputPath);
    }
    return builder;
  }
}

class VaneMultipartFile {
  const VaneMultipartFile({
    required this.fieldName,
    required this.bytes,
    this.fileName,
    this.contentType = 'application/octet-stream',
  });

  final String fieldName;
  final Uint8List bytes;
  final String? fileName;
  final String contentType;
}

class VaneProgress {
  const VaneProgress({
    required this.uploadSent,
    required this.uploadTotal,
    required this.downloadReceived,
    required this.downloadTotal,
    required this.done,
  });

  final int uploadSent;
  final int uploadTotal;
  final int downloadReceived;
  final int downloadTotal;
  final bool done;
}

/// Cancels an in-flight request.
///
/// Caller-owned. Cancelling latches, so a token cancelled before or during a
/// request aborts that request even if the intent arrived first; [dispose]
/// clears the latch as well as the native id, so a disposed token is inert and
/// can be reused. Create one per request and dispose it in a `finally`.
///
/// [cancel] may be called before the request starts — including in the same
/// microtask as the `execute` that will use it. The intent is latched and
/// replayed the moment the token registers with the core, so the request is
/// stopped before its first hop rather than running to completion.
class VaneCancelToken {
  VaneFlutterPlatform? _platform;
  int? _id;
  bool _cancelled = false;

  bool get isStarted => _id != null;

  /// Whether [cancel] has been called, whether or not the core had registered
  /// the token yet.
  bool get isCancelled => _cancelled;

  Future<void> cancel() async {
    // Latch first and unconditionally: a cancel that lands before the token
    // has a native id used to be discarded outright, so the request ran to
    // completion with its response thrown away.
    _cancelled = true;
    final id = _id;
    final platform = _platform;
    if (id != null && platform != null) {
      await platform.cancelToken(id);
    }
  }

  Future<void> dispose() async {
    final id = _id;
    final platform = _platform;
    _id = null;
    _platform = null;
    // Disarm the latch too. Both adapters dispose in a `finally` after
    // `execute` has returned or thrown, so the intent has already been
    // replayed; leaving it set would make a reused token cancel every later
    // request forever, with no public way to reset it.
    _cancelled = false;
    if (id != null && platform != null) {
      await platform.freeCancelToken(id);
    }
  }
}

class Vane {
  Vane._();

  static VaneClient _shared = VaneClient();

  static VaneClient get shared => _shared;

  static Future<void> configure({
    VaneConfiguration configuration = const VaneConfiguration(),
    List<VaneRequestInterceptor> requestInterceptors = const [],
    List<VaneResponseInterceptor> responseInterceptors = const [],
    List<VaneErrorInterceptor> errorInterceptors = const [],
  }) async {
    await _shared.close();
    _shared = VaneClient(
      configuration: configuration,
      requestInterceptors: requestInterceptors,
      responseInterceptors: responseInterceptors,
      errorInterceptors: errorInterceptors,
    );
  }

  static VaneRequestBuilder request(String url, {String method = 'GET'}) {
    return _shared.request(url, method: method);
  }

  static void addRequestInterceptor(VaneRequestInterceptor interceptor) {
    _shared.addRequestInterceptor(interceptor);
  }

  static void addResponseInterceptor(VaneResponseInterceptor interceptor) {
    _shared.addResponseInterceptor(interceptor);
  }

  static void addErrorInterceptor(VaneErrorInterceptor interceptor) {
    _shared.addErrorInterceptor(interceptor);
  }

  static void clearInterceptors() {
    _shared.clearInterceptors();
  }

  static Future<VaneResponse> get(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.get(url, options: options);
  }

  static Future<VaneResponse> delete(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.delete(url, options: options);
  }

  static Future<VaneResponse> post(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.post(url, body: body, options: options);
  }

  static Future<VaneResponse> put(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.put(url, body: body, options: options);
  }

  static Future<VaneResponse> patch(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.patch(url, body: body, options: options);
  }

  static Future<VaneResponse> postJson(
    String url,
    Object? value, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.postJson(url, value, options: options);
  }

  static Future<VaneResponse> postForm(
    String url,
    Map<String, String> fields, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.postForm(url, fields, options: options);
  }

  static Future<VaneResponse> uploadFile(
    String url,
    String path, {
    String method = 'POST',
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.uploadFile(url, path, method: method, options: options);
  }

  static Future<VaneResponse> download(
    String url,
    String outputPath, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return _shared.download(url, outputPath, options: options);
  }

  static Future<void> setCertificatePins(String host, List<String> pins) {
    return _shared.setCertificatePins(host, pins);
  }

  static Future<void> clearCertificatePins(String host) {
    return _shared.clearCertificatePins(host);
  }

  static Future<void> close() => _shared.close();
}

class VaneClient {
  VaneClient({
    VaneConfiguration configuration = const VaneConfiguration(),
    List<VaneRequestInterceptor> requestInterceptors = const [],
    List<VaneResponseInterceptor> responseInterceptors = const [],
    List<VaneErrorInterceptor> errorInterceptors = const [],
    VaneFlutterPlatform? platform,
  }) : _configuration = configuration,
       _requestInterceptors = List<VaneRequestInterceptor>.of(
         requestInterceptors,
       ),
       _responseInterceptors = List<VaneResponseInterceptor>.of(
         responseInterceptors,
       ),
       _errorInterceptors = List<VaneErrorInterceptor>.of(errorInterceptors),
       _platform = platform ?? VaneFlutterPlatform.instance;

  final VaneConfiguration _configuration;
  final List<VaneRequestInterceptor> _requestInterceptors;
  final List<VaneResponseInterceptor> _responseInterceptors;
  final List<VaneErrorInterceptor> _errorInterceptors;
  final VaneFlutterPlatform _platform;
  int? _handle;
  bool _closed = false;

  Future<int> _ensureHandle() async {
    if (_closed) {
      // Terminal on purpose: without this, anything that races [close] — a
      // dispose() while a request is in flight, say — silently creates a
      // second native client that nobody is left holding to close.
      throw StateError(
        'This VaneClient is closed. Create a new one instead of reusing it.',
      );
    }
    return _handle ??= await _platform.createClient(_configuration.toMap());
  }

  VaneRequestBuilder request(String url, {String method = 'GET'}) {
    return VaneRequestBuilder._(this, url, method.toUpperCase());
  }

  VaneClient addRequestInterceptor(VaneRequestInterceptor interceptor) {
    _requestInterceptors.add(interceptor);
    return this;
  }

  VaneClient addResponseInterceptor(VaneResponseInterceptor interceptor) {
    _responseInterceptors.add(interceptor);
    return this;
  }

  VaneClient addErrorInterceptor(VaneErrorInterceptor interceptor) {
    _errorInterceptors.add(interceptor);
    return this;
  }

  VaneClient clearInterceptors() {
    _requestInterceptors.clear();
    _responseInterceptors.clear();
    _errorInterceptors.clear();
    return this;
  }

  Future<void> setCertificatePins(String host, List<String> pins) async {
    final handle = await _ensureHandle();
    await _platform.setCertificatePins(handle, host, pins);
  }

  /// Best-effort warm-up of this client's one-time setup and connection
  /// cost, so the first real request doesn't pay it — on Android the TCP
  /// transport's first request otherwise carries ~1 s of trust-store and
  /// runtime setup. Call it once, early (e.g. right after `runApp`); it
  /// never throws for network reasons and repeat calls are cheap.
  ///
  /// [url] picks the origin to pre-connect (HTTP/3) or probe (TCP); when
  /// null, the configuration's `baseUrl` is used. With neither, only the
  /// native client construction is warmed. Creates the native client if this
  /// one has not made a request yet — that construction is part of what gets
  /// warmed.
  Future<void> warmup([String? url]) async {
    final handle = await _ensureHandle();
    await _platform.warmup(handle, url);
  }

  Future<void> clearCertificatePins(String host) {
    return setCertificatePins(host, const <String>[]);
  }

  Future<VaneResponse> get(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url)).execute();
  }

  Future<VaneResponse> delete(
    String url, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url, method: 'DELETE')).execute();
  }

  Future<VaneResponse> post(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'POST'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> put(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'PUT'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> patch(
    String url, {
    Uint8List? body,
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    final builder = options.applyTo(request(url, method: 'PATCH'));
    if (body != null) {
      builder.body(body);
    }
    return builder.execute();
  }

  Future<VaneResponse> postJson(
    String url,
    Object? value, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: 'POST'))
        .jsonBody(value)
        .execute();
  }

  Future<VaneResponse> postForm(
    String url,
    Map<String, String> fields, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: 'POST'))
        .formBody(fields)
        .execute();
  }

  Future<VaneResponse> uploadFile(
    String url,
    String path, {
    String method = 'POST',
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options
        .applyTo(request(url, method: method))
        .bodyFile(path)
        .execute();
  }

  Future<VaneResponse> download(
    String url,
    String outputPath, {
    VaneRequestOptions options = const VaneRequestOptions(),
  }) {
    return options.applyTo(request(url)).downloadToFile(outputPath).execute();
  }

  Future<VaneResponse> execute(VaneRequest request) async {
    var interceptedRequest = request;
    for (final interceptor in List<VaneRequestInterceptor>.of(
      _requestInterceptors,
    )) {
      interceptedRequest = await interceptor(interceptedRequest);
    }

    Timer? progressTimer;
    int? progressId;
    try {
      final handle = await _ensureHandle();
      final cancelToken = interceptedRequest.cancelToken;
      if (cancelToken != null && cancelToken._id == null) {
        cancelToken
          .._platform = _platform
          .._id = await _platform.createCancelToken();
        // Replay a cancel that landed while the token had no native id, so it
        // reaches the core before `toMap` snapshots the id below.
        if (cancelToken._cancelled) {
          await cancelToken.cancel();
        }
      }
      if (interceptedRequest.onUploadProgress != null ||
          interceptedRequest.onDownloadProgress != null) {
        progressId = await _platform.createProgress();
        progressTimer = Timer.periodic(const Duration(milliseconds: 100), (
          _,
        ) async {
          final id = progressId;
          if (id == null) {
            return;
          }
          final progress = await _platform.progressSnapshot(id);
          interceptedRequest.onUploadProgress?.call(
            progress.uploadSent,
            progress.uploadTotal,
          );
          interceptedRequest.onDownloadProgress?.call(
            progress.downloadReceived,
            progress.downloadTotal,
          );
          if (progress.done) {
            progressTimer?.cancel();
          }
        });
      }
      final requestMap = interceptedRequest.toMap();
      requestMap['progressId'] = progressId;
      var response = await _platform.execute(handle, requestMap);
      for (final interceptor in List<VaneResponseInterceptor>.of(
        _responseInterceptors,
      )) {
        response = await interceptor(response);
      }
      return response;
    } catch (error, stackTrace) {
      for (final interceptor in List<VaneErrorInterceptor>.of(
        _errorInterceptors,
      )) {
        final response = await interceptor(error, stackTrace);
        if (response != null) {
          var interceptedResponse = response;
          for (final responseInterceptor in List<VaneResponseInterceptor>.of(
            _responseInterceptors,
          )) {
            interceptedResponse = await responseInterceptor(
              interceptedResponse,
            );
          }
          return interceptedResponse;
        }
      }
      rethrow;
    } finally {
      progressTimer?.cancel();
      if (progressId != null) {
        final progress = await _platform.progressSnapshot(progressId);
        interceptedRequest.onUploadProgress?.call(
          progress.uploadSent,
          progress.uploadTotal,
        );
        interceptedRequest.onDownloadProgress?.call(
          progress.downloadReceived,
          progress.downloadTotal,
        );
        await _platform.freeProgress(progressId);
      }
    }
  }

  /// Like [execute], but resolves as soon as the final response's headers are
  /// in, with the body left to stream; see [VaneStreamingResponse].
  ///
  /// Everything up to the headers behaves exactly like [execute]: the same
  /// redirect chain, retry policy, HTTP/3-to-TCP fallback, cookies, pins and
  /// deadline. Differences, all deliberate:
  ///
  /// - Request interceptors run; response and error interceptors do NOT — an
  ///   interceptor written against a buffered [VaneResponse] cannot rewrite a
  ///   body that has not arrived. Validate status off the head, e.g.
  ///   `response.head.validateStatus()`.
  /// - [VaneRequest.responseBodyPath] is refused by the core: the stream
  ///   replaces the file escape hatch.
  /// - Progress callbacks are ignored: the chunks themselves are the
  ///   download progress.
  /// - [VaneRequest.cancelToken] composes: cancelling it aborts the header
  ///   phase, or fails the body stream mid-flight. Cancelling the body
  ///   subscription cancels it too. When no token is given, the platform
  ///   runs one internally so cancellation stays prompt.
  Future<VaneStreamingResponse> executeStreaming(VaneRequest request) async {
    var interceptedRequest = request;
    for (final interceptor in List<VaneRequestInterceptor>.of(
      _requestInterceptors,
    )) {
      interceptedRequest = await interceptor(interceptedRequest);
    }
    final handle = await _ensureHandle();
    final cancelToken = interceptedRequest.cancelToken;
    if (cancelToken != null && cancelToken._id == null) {
      cancelToken
        .._platform = _platform
        .._id = await _platform.createCancelToken();
      // Replay a cancel that landed while the token had no native id, same
      // as [execute].
      if (cancelToken._cancelled) {
        await cancelToken.cancel();
      }
    }
    return _platform.executeStreaming(handle, interceptedRequest.toMap());
  }

  /// Closes the native client. The instance is spent afterwards: further
  /// requests throw a [StateError] rather than quietly opening a new one.
  Future<void> close() async {
    _closed = true;
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await _platform.closeClient(handle);
    }
  }
}

class VaneRequestBuilder {
  VaneRequestBuilder._(this._client, String url, String method)
    : _request = VaneRequest(url: url, method: method);

  final VaneClient _client;
  VaneRequest _request;

  VaneRequestBuilder headers(Map<String, String> headers) {
    _request = _request.copyWith(headers: Map<String, String>.of(headers));
    return this;
  }

  VaneRequestBuilder header(String key, String value) {
    _request = _request.copyWith(
      headers: <String, String>{..._request.headers, key: value},
    );
    return this;
  }

  VaneRequestBuilder queryParams(Map<String, String> params) {
    _request = _request.copyWith(queryParams: Map<String, String>.of(params));
    return this;
  }

  VaneRequestBuilder queryParam(String key, String value) {
    _request = _request.copyWith(
      queryParams: <String, String>{..._request.queryParams, key: value},
    );
    return this;
  }

  VaneRequestBuilder body(Uint8List body) {
    _request = VaneRequest(
      url: _request.url,
      method: _request.method,
      headers: _request.headers,
      queryParams: _request.queryParams,
      body: body,
      responseBodyPath: _request.responseBodyPath,
      cancelToken: _request.cancelToken,
      onUploadProgress: _request.onUploadProgress,
      onDownloadProgress: _request.onDownloadProgress,
      timeoutSeconds: _request.timeoutSeconds,
      followRedirects: _request.followRedirects,
    );
    return this;
  }

  VaneRequestBuilder bodyFile(String path) {
    _request = VaneRequest(
      url: _request.url,
      method: _request.method,
      headers: _request.headers,
      queryParams: _request.queryParams,
      bodyFilePath: path,
      responseBodyPath: _request.responseBodyPath,
      cancelToken: _request.cancelToken,
      onUploadProgress: _request.onUploadProgress,
      onDownloadProgress: _request.onDownloadProgress,
      timeoutSeconds: _request.timeoutSeconds,
      followRedirects: _request.followRedirects,
    );
    return this;
  }

  VaneRequestBuilder downloadToFile(String path) {
    _request = _request.copyWith(responseBodyPath: path);
    return this;
  }

  VaneRequestBuilder cancelToken(VaneCancelToken token) {
    _request = _request.copyWith(cancelToken: token);
    return this;
  }

  VaneRequestBuilder onUploadProgress(VaneProgressCallback callback) {
    _request = _request.copyWith(onUploadProgress: callback);
    return this;
  }

  VaneRequestBuilder onDownloadProgress(VaneProgressCallback callback) {
    _request = _request.copyWith(onDownloadProgress: callback);
    return this;
  }

  VaneRequestBuilder multipart({
    Map<String, String> fields = const <String, String>{},
    Map<String, Uint8List> files = const <String, Uint8List>{},
    List<VaneMultipartFile> fileParts = const <VaneMultipartFile>[],
  }) {
    final boundary = 'vane-${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder();
    for (final entry in fields.entries) {
      body
        ..add(utf8.encode('--$boundary\r\n'))
        ..add(
          utf8.encode(
            'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n',
          ),
        )
        ..add(utf8.encode(entry.value))
        ..add(utf8.encode('\r\n'));
    }
    for (final entry in files.entries) {
      _appendMultipartFile(
        body,
        boundary,
        fieldName: entry.key,
        fileName: entry.key,
        contentType: 'application/octet-stream',
        bytes: entry.value,
      );
    }
    for (final part in fileParts) {
      _appendMultipartFile(
        body,
        boundary,
        fieldName: part.fieldName,
        fileName: part.fileName ?? part.fieldName,
        contentType: part.contentType,
        bytes: part.bytes,
      );
    }
    body.add(utf8.encode('--$boundary--\r\n'));
    return this
        .body(body.toBytes())
        ._defaultHeader(
          'Content-Type',
          'multipart/form-data; boundary=$boundary',
        );
  }

  void _appendMultipartFile(
    BytesBuilder body,
    String boundary, {
    required String fieldName,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
  }) {
    body
      ..add(utf8.encode('--$boundary\r\n'))
      ..add(
        utf8.encode(
          'Content-Disposition: form-data; name="$fieldName"; filename="$fileName"\r\n',
        ),
      )
      ..add(utf8.encode('Content-Type: $contentType\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n'));
  }

  VaneRequestBuilder textBody(
    String text, {
    Encoding encoding = utf8,
    String contentType = 'text/plain; charset=utf-8',
  }) {
    return body(
      Uint8List.fromList(encoding.encode(text)),
    )._defaultHeader('Content-Type', contentType);
  }

  VaneRequestBuilder jsonBody(Object? value) {
    return body(
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
    )._defaultHeader('Content-Type', 'application/json');
  }

  VaneRequestBuilder formBody(Map<String, String> fields) {
    final entries = fields.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final encoded = entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&')
        .replaceAll('%20', '+');
    return body(
      Uint8List.fromList(utf8.encode(encoded)),
    )._defaultHeader('Content-Type', 'application/x-www-form-urlencoded');
  }

  VaneRequestBuilder timeout(int seconds) {
    _request = _request.copyWith(timeoutSeconds: seconds);
    return this;
  }

  VaneRequestBuilder followRedirects(bool follow) {
    _request = _request.copyWith(followRedirects: follow);
    return this;
  }

  Future<VaneResponse> execute() => _client.execute(_request);

  /// Executes with a streamed response body; see
  /// [VaneClient.executeStreaming] for how this differs from [execute].
  Future<VaneStreamingResponse> executeStreaming() =>
      _client.executeStreaming(_request);

  Future<VaneResponse> validateStatus([int min = 200, int max = 299]) async {
    return (await execute()).validateStatus(min, max);
  }

  Future<Uint8List> responseBytes() async => (await validateStatus()).body;
  Future<String> responseString() async => (await validateStatus()).text;
  Future<T> responseJson<T>() async => (await validateStatus()).json<T>();

  VaneRequestBuilder _defaultHeader(String key, String value) {
    final hasHeader = _request.headers.keys.any(
      (existing) => existing.toLowerCase() == key.toLowerCase(),
    );
    if (!hasHeader) {
      header(key, value);
    }
    return this;
  }
}
