#### Bitcoin and Lightning packages in bitcoinix

bitcoinix now packages bitcoind, BTCPay Server, charge-lnd, CLBOSS, Core Lightning,
electrs, Fulcrum, lnd, lndconnect, lndinit, RTL and TrustedCoin itself, like NBXplorer.
They're copies of the nixpkgs packages at the same versions, so their store paths
don't change. With `nix-bitcoin.useVersionLockedPkgs = false` or a non-flake module
import, they keep these versions and build with your system's nixpkgs, and overlays
on them don't apply. The flake's packages and its `overlays.default` now have them
too. `pinned.<name>` stays the nixpkgs package, so `pinned.trustedcoin` no longer has
TrustedCoin's two startup patches; use `trustedcoin` instead.
