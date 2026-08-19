# Local libssh2 patches

SSHApp builds the immutable `vendor/libssh2` pin from a disposable source copy
and applies the numbered patches in this directory in lexical order. The vendor
submodule itself must remain clean.

- `0001-userauth-banner-callback.patch` adds an upstreamable RFC 4252
  `SSH_MSG_USERAUTH_BANNER` callback. It observes every valid pre-authentication
  banner after transport integrity checks without consuming the packet, and
  includes a focused standalone libssh2 test.

`build-libssh2.sh` uses zero patch fuzz and includes every numbered patch in its
input hash. Changing a patch therefore invalidates all generated libssh2/OpenSSL
frameworks.
