#### Bitcoin network selection

Replace `services.bitcoind.regtest = true;` with `services.bitcoind.network = "regtest";`.
If you explicitly set `services.bitcoind.regtest = false;`, remove it or set
`services.bitcoind.network = "mainnet";` (the default). The new option selects the
network for the whole deployment; existing network-specific paths and ports
are unchanged.

The old boolean is forwarded to `network` during migration, so upgrade notices
still use the network and paths from your existing configuration. It emits a
deprecation warning if used after updating `configVersion`.
