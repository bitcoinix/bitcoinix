#### Unbeholden Wallet behind a remote proxy

Unbeholden Wallet only accepted connections from localhost, so `address = "0.0.0.0"`
alone didn't let a reverse proxy on another host reach it. List the proxy's address in
the new `services.unbeholden-wallet.allowedClients` option, see
[Access from another device](../../services.md#access-from-another-device).
