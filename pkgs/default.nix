let
  nixpkgsPinned = import ./nixpkgs-pinned.nix;
in
# Set default values for use without flakes
{ pkgs ? import <nixpkgs> { config = {}; overlays = []; }
, pkgsUnstable ? import nixpkgsPinned.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = {};
    overlays = [];
  }
}:
let self = {
  clightning-plugins = pkgs.lib.recurseIntoAttrs (import ./clightning-plugins pkgs self.nbPython3Packages);
  clnrest = pkgs.callPackage ./clnrest { inherit (self.pinned) clightning; };
  rtl = pkgs.callPackage ./rtl { inherit (self) fetchNodeModules; };
  inherit (pkgs.callPackage ./mempool { inherit (self) fetchNodeModules; })
    mempool-backend
    mempool-frontend
    mempool-rust-gbt
    mempool-nginx-conf;
  rbitcoin = pkgs.callPackage ./rbitcoin { };
  trustedcoin = pkgs.callPackage ./trustedcoin { };

  inherit (self.pyPkgs.nbPython3PackagesWithUnlockedEcdsa) hwi;

  pyPkgs = import ./python-packages self pkgs.python3;
  inherit (self.pyPkgs)
    nbPython3Packages;

  fetchNodeModules = pkgs.callPackage ./build-support/fetch-node-modules.nix { };

  # Internal pkgs
  krops = import ./krops { inherit pkgs; };

  pinned = import ./pinned.nix pkgs pkgsUnstable;

  modulesPkgs = self // self.pinned;
}; in self
