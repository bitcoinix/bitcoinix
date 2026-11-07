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
  rtl = pkgs.callPackage ./rtl { inherit (self) fetchNodeModules; };
  inherit (pkgs.callPackage ./mempool { inherit (self) fetchNodeModules; })
    mempool-backend
    mempool-frontend
    mempool-rust-gbt
    mempool-nginx-conf;
  trustedcoin = pkgs.callPackage ./trustedcoin { };

  inherit (self.pyPkgs.nbPython3PackagesWithUnlockedEcdsa) hwi;

  pyPkgs = import ./python-packages self pkgs.python3;
  inherit (self.pyPkgs)
    nbPython3Packages;

  fetchNodeModules = pkgs.callPackage ./build-support/fetch-node-modules.nix { };

  # Internal pkgs
  krops = import ./krops { inherit pkgs; };

  pinned = import ./pinned.nix pkgs;

  modulesPkgs = self // self.pinned;
}; in self
