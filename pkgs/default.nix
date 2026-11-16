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
  unbeholden-wallet = pkgs.callPackage ./unbeholden-wallet {};
  unbeholden-lnurl = pkgs.callPackage ./unbeholden-lnurl { };

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
      electrs
      extra-container
      fulcrum
      lnd
      lndconnect
      lndinit
      nbxplorer
      rtl;

    inherit pkgs;

    trustedcoin = pkgs.trustedcoin.overrideAttrs (old: {
      patches = (old.patches or []) ++ [
        # Fix getchaininfo initialization races and reporting height 0 without a source.
        # https://github.com/nbd-wtf/trustedcoin/pull/44
        (pkgs.fetchpatch {
          url = "https://github.com/nbd-wtf/trustedcoin/commit/3210fc9a5893cde597905dd3e6577d9791ae690d.patch";
          hash = "sha256-OPkZOf3t13Ti//WWfHII+KXSreXYYj2ogmRL0KZ5nvY=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/nbd-wtf/trustedcoin/commit/21a1f43ffd558f79e145ae70f26f682eef19c1fe.patch";
          hash = "sha256-1Sr1WQYmCEmJpTq/YMxWx3EtE8xP+4fZKwgQUksc6CU=";
        })
      ];
    });
  };

  modulesPkgs = self // self.pinned;
}; in self
