let
  nixpkgsPinned = import ./nixpkgs-pinned.nix;
in
# Set default values for use without flakes
{ pkgs ? import nixpkgsPinned.nixpkgs { config = {}; overlays = []; }
}:
let self = {
  clightning-plugins = pkgs.lib.recurseIntoAttrs (
    (import ./clightning-plugins/python.nix pkgs self.nbPython3Packages) // {
      inherit (pkgs.callPackage ./clightning-plugins/rust.nix { inherit (self.pinned) clightning; })
        clnrest currencyrate;
    }
  );
  inherit (pkgs.callPackage ./mempool { inherit (self) fetchNodeModules; })
    mempool-backend
    mempool-frontend
    mempool-rust-gbt
    mempool-nginx-conf;

  inherit (self.pyPkgs.nbPython3PackagesWithUnlockedEcdsa) hwi;

  pyPkgs = import ./python-packages pkgs pkgs.python3;
  inherit (self.pyPkgs)
    nbPython3Packages;

  fetchNodeModules = pkgs.callPackage ./build-support/fetch-node-modules.nix { };

  # Internal pkgs
  krops = import ./krops { inherit pkgs; };

  pinned = {
    inherit (pkgs)
      bitcoind
      btcpayserver
      charge-lnd
      clboss
      clightning
      extra-container
      fulcrum
      lnd
      lndconnect
      lndinit
      nbxplorer
      rtl;

    inherit pkgs;

    trustedcoin = pkgs.trustedcoin.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ./trustedcoin/wait-for-initialization.patch ];
    });
    # TODO-EXTERNAL: Remove when nixpkgs electrs declares its zstd build inputs.
    # zstd-sys uses pkg-config to find the system library.
    electrs = pkgs.electrs.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.pkg-config ];
      buildInputs = (old.buildInputs or []) ++ [ pkgs.zstd ];
    });
  };

  modulesPkgs = self // self.pinned;
}; in self
