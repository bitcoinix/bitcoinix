let
  nixpkgsPinned = import ./nixpkgs-pinned.nix;
in
# Set default values for use without flakes
{ pkgs ? import nixpkgsPinned.nixpkgs { config = {}; overlays = []; }
}:
let
  # Packages copied from nixpkgs into ./by-name/<name>, so that bitcoinix can update them on
  # its own schedule. Each one replaces the `pinned` package of the same name. The
  # stale-packages check fails when nixpkgs has a newer version.
  # The names come from builtins only, as `overlays.default` calls this file with its own
  # result as `pkgs`.
  byNameDirs = let
    entries = if builtins.pathExists ./by-name then builtins.readDir ./by-name else { };
  in
    builtins.filter (name: entries.${name} == "directory") (builtins.attrNames entries);
  byName = builtins.listToAttrs (map (name: {
    inherit name;
    value = pkgs.callPackage ./by-name/${name}/package.nix (byNameArgs.${name} or { });
  }) byNameDirs);
  # As in nixpkgs, bitcoind is package `bitcoin` without the GUI
  byNameArgs.bitcoind.withGui = false;
in
let self = byName // {
  clightning-plugins = pkgs.lib.recurseIntoAttrs (
    (import ./clightning-plugins/python.nix pkgs self.nbPython3Packages) // {
      inherit (pkgs.callPackage ./clightning-plugins/rust.nix { inherit (self.modulesPkgs) clightning; })
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
      rtl
      trustedcoin;

    inherit pkgs;
  };

  modulesPkgs = self.pinned // self;
}; in self
