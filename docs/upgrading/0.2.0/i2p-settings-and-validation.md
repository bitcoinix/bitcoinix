#### I2P settings and validation

For custom i2pd configuration, replace `services.i2pd.proto.sam` with
`services.i2pd.settings.sam` and rename its `enable` field to `enabled`.
bitcoinix still enables SAM automatically for `services.bitcoind.i2p` and
sets its address for namespace isolation.
The web console, HTTP proxy and SOCKS proxy remain disabled by default, and
NTCP2/SSU2 address publication remains disabled. Explicit opt-ins through
`services.i2pd.settings` still take precedence.

With namespace isolation, bitcoinix disables `services.i2pd.checkConfig` by
default: the upstream build-time check starts i2pd and cannot bind the namespace
bridge address inside the build sandbox. Custom setting errors can therefore
surface only when the service starts. After changing I2P settings, check
`systemctl status i2pd` and `journalctl -u i2pd`, and verify bitcoind can reach
the SAM listener. The `i2p` VM scenario exercises this bridge listener and
`i2pLocal` covers the loopback listener with the upstream check enabled; these
tests do not validate your custom configuration.
