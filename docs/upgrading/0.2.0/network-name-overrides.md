#### Network name overrides

The read-only `services.bitcoind.makeNetworkName` helper has been removed.
Replace calls such as `config.services.bitcoind.makeNetworkName "bitcoin" "regtest"`
with the new helper, specifying only names that need overriding. In a NixOS
module taking `config` as an argument, define `nbLib` before using the short name:

```nix
let
  nbLib = config.nix-bitcoin.lib;
in
  nbLib.networkName { mainnet = "bitcoin"; }
```

This returns `"bitcoin"` on mainnet and `"regtest"` on regtest. Unmapped network
names pass through unchanged.
