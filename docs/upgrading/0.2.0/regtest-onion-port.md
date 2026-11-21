#### Regtest onion target port

On regtest, bitcoinix now maps the public onion port `18444` to the local
bitcoind listener on `18445` by default. The generated Tor mapping updates
automatically.

If you manage a separate Tor mapping that forwards to `8334`, update its
target to `18445` or set `services.bitcoind.onionPort = 8334;` to keep using
the old listener.
