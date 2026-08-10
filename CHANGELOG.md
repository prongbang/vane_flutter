## Unreleased

* `VaneResponse.setCookie` — the raw `Set-Cookie` values from the final
  response, in wire order. Unfiltered: a cookie Vane's own jar refused still
  appears here. Never present in `headers`, which cannot hold repeats.
* `VaneResponse.httpVersion` — the protocol that served the final response
  (`VaneHttpVersion.http10/http11/http2/http3`), or null when no exchange
  completed. The dio adapter now sets `ResponseBody.extraKeyHttpVersion`, and
  the `package:http` adapter comma-joins `set-cookie` into its headers map the
  way `IOClient` does.
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
