#### Bitcoin network selection

Select the Bitcoin network with `services.bitcoind.network` (`"mainnet"` or
`"regtest"`) instead of `services.bitcoind.regtest`. The `makeNetworkName` helper
is replaced by `nix-bitcoin.lib.networkName`, which accepts name overrides and
passes other network names through unchanged. See the migration instructions for
[selecting a network](../../upgrading/0.2.0/bitcoin-network-selection.md) and
[overriding network names](../../upgrading/0.2.0/network-name-overrides.md).
