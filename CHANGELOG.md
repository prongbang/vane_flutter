## Unreleased

* Response-body streaming: `VaneClient.executeStreaming` (and
  `executeStreaming()` on the request builder) resolves at the final
  response's headers with a `VaneStreamingResponse` — the usual head plus a
  single-subscription, demand-driven `Stream<Uint8List>` body. Chunks are
  pulled from the native transport only as the listener consumes them, so a
  paused consumer stalls the sender through QUIC/TCP flow control instead of
  buffering; cancelling the subscription aborts the transfer. Request
  interceptors run; response/error interceptors and progress callbacks do
  not apply to the streaming path, and `responseBodyPath` is refused. FFI
  platform only — the MethodChannel fallback stays buffered by design. The
  C ABI version this package expects moves 2 → 3: update `libvane` and this
  package together.
* `VaneResponse.setCookie` — the raw `Set-Cookie` values from the final
  response, in wire order. Unfiltered: a cookie Vane's own jar refused still
  appears here. Never present in `headers`, which cannot hold repeats.
* `VaneResponse.httpVersion` — the protocol that served the final response
  (`VaneHttpVersion.http10/http11/http2/http3`), or null when no exchange
  completed. The dio adapter now sets `ResponseBody.extraKeyHttpVersion`, and
  the `package:http` adapter comma-joins `set-cookie` into its headers map the
  way `IOClient` does.
* Behaviour change: a non-cookie response header the server repeated is now
  comma-joined into one `"a, b"` value (RFC 9110 §5.2), identically on both
  transports. It previously kept a single value — the first on HTTP/3, the
  last on the TCP fallback — so which one a caller saw depended on the
  transport. `package:http`'s `headersSplitValues` and dio's list inflation
  split the joined value back apart; `set-cookie` stays the
  `VaneResponse.setCookie` list as before.
* `VaneCancelToken.cancel()` now latches. A cancel issued before the request
  reached the core used to be discarded, letting the request run to completion
  with its response thrown away; it is now replayed at registration and the
  native request is stopped. The latch survives until `dispose()`, which clears
  it along with the native id — dispose in a `finally`, as both adapters do, or
  a reused token cancels the next request too.
* Upgrading: **Dart and `libvane` must move together.** The `#[repr(C)]`
  `VaneFfiResponse` did not grow and no existing field moved, but the contract
  around it changed in two ways that no version signal catches.
  - `http_version` occupies offset 3, which was pure padding before. New Dart
    against an older core reads uninitialized bytes there and reports a
    confident, wrong protocol rather than null.
  - The C ABI header array now contains repeated `set-cookie` keys — it has
    always been a `(key, value)` list rather than a map, but `set-cookie` never
    appeared in it before. Out-of-repo consumers that fold the array into a map
    must route `set-cookie` out first, or N cookies collapse to one arbitrary
    value. Old Dart against a newer core does exactly that.
* Note for anyone stacking a third-party cookie store (dio's `CookieManager`,
  a `package:http` session library) on top of Vane: the surfaced values are
  what the server sent, not what Vane's jar accepted, and they are surfaced
  even when `VaneConfiguration.cookiesEnabled` is false. That setting stops
  Vane's own jar; it does not stop a second store you install yourself.

## 0.0.1

* TODO: Describe initial release.
