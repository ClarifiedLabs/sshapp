# Local libssh2 patches

SSHApp builds the immutable `vendor/libssh2` pin from a disposable source copy
and applies the numbered patches in this directory in lexical order. The vendor
submodule itself must remain clean. Current patch base: libssh2
`6125bfe552b3a8c7340c2fb3b82cdf65b0e16f9d` (`1.11.2_DEV`, unreleased).

- `0001-userauth-banner-callback.patch` adds an upstreamable RFC 4252
  `SSH_MSG_USERAUTH_BANNER` callback. It observes every valid pre-authentication
  banner after transport integrity and strict-KEX checks without consuming or
  changing queued packets. Callback ABI slot `10` remains unoccupied upstream.
  Message and language are borrowed explicit-length byte ranges; the synchronous
  callback must not block or reenter authentication or transport processing on
  the same session. Invalid-MAC packets never trigger it, even when accepted by
  a MAC-error callback.
  The patch uses upstream's `ssh2_*`/`SSH2_*` internal helpers, Markdown API docs,
  and static standalone test registration shared by CMake and Automake.
  Rebased for upstream's `send_cb`/`recv_cb` session-member rename; callback
  behavior and ABI are unchanged.

  Its standalone test covers repeated/embedded-NUL/empty banners, unchanged
  queuing, malformed fields, callback replacement and disabling, authentication
  state, invalid MACs (including overrides), and strict-KEX rejection. Run
  `scripts/test-libssh2-banner-callback.sh` for the focused native and app-bridge
  tests (requires CMake and host OpenSSL).

`build-libssh2.sh` uses zero patch fuzz and includes every numbered patch in its
input hash. Changing a patch therefore invalidates all generated libssh2/OpenSSL
frameworks.
