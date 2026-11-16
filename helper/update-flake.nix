{ prevVersions ? null }:
let
  flake = builtins.getFlake (toString ../.);
  inherit (flake.inputs.nixpkgs) lib;
in rec {
  # All pinned packages come from the single unstable nixpkgs input.
  versions = let
    pinned = flake.legacyPackages.x86_64-linux.pinned;
    pinnedPkgs = lib.filterAttrs (_: lib.isDerivation) pinned;
  in lib.mapAttrs (_: pkg: pkg.version) pinnedPkgs;

  showUpdates = let
    prev = builtins.fromJSON prevVersions;
    changes = lib.concatMap (name:
      let version = versions.${name}; in
      lib.optional (prev ? ${name} && prev.${name} != version)
        "${name}: ${prev.${name}} -> ${version}"
    ) (builtins.attrNames versions);
  in
    if changes == [] then "No pkg version updates."
    else builtins.concatStringsSep "\n" ([ "Pkg updates in nixpkgs unstable:" ] ++ changes);

  versionsFile = let
    # Skip the demo VM outputs to avoid evaluating a NixOS system for the manifest.
    packages = builtins.removeAttrs flake.packages.x86_64-linux [ "runVM" "vm" ];
    localPkgs = lib.filterAttrs (_: pkg: pkg ? version) packages;
  in
    lib.mapAttrs (_: version: {
      inherit version;
      channel = "unstable";
    }) versions
    // lib.mapAttrs (_: pkg: {
      inherit (pkg) version;
      channel = "local";
    }) localPkgs;
}
