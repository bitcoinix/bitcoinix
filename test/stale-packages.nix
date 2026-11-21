# Fails when the nixpkgs pin has caught up with a package that bitcoinix carries:
# - an entry of ../pkgs/security-fixes.nix whose `fixedIn` version the pin has
# - a top-level package of ../pkgs/default.nix that the pin has under the same name,
#   in a newer version, or at the same version with a different derivation
{ pkgs, nbPkgs, fixes ? (import ../pkgs/security-fixes.nix).fixes }:
let
  inherit (pkgs) lib;

  # Packages that bitcoinix changes on purpose at the pin's version
  changedOnPurpose = [ ];

  staleFixes = lib.concatMap (name: let
    inherit (pkgs.${name}) version;
    inherit (fixes.${name}) fixedIn;
  in lib.optional (lib.versionAtLeast version fixedIn)
    "${name}: nixpkgs has ${version}, so remove its entry (fixedIn ${fixedIn}) from pkgs/security-fixes.nix."
  ) (builtins.attrNames fixes);

  # A value of a nixpkgs package, or null if nixpkgs doesn't have it,
  # or has only an alias or a package that throws
  tryGet = f: let result = builtins.tryEval (f null); in
    if result.success then result.value else null;

  localPkgs = lib.filterAttrs (_: pkg: lib.isDerivation pkg && pkg ? version) nbPkgs;
  outdatedPkgs = lib.concatMap (name: let
    local = localPkgs.${name};
    pinVersion = tryGet (_: pkgs.${name}.version or null);
    pinDrv = tryGet (_: pkgs.${name}.drvPath);
  in
    if pinVersion == null then [ ]
    else if lib.versionOlder local.version pinVersion then [
      "${name}: nixpkgs has ${pinVersion}, newer than ${local.version} in pkgs/, so update or remove the package."
    ] else if local.version == pinVersion && pinDrv != null && local.drvPath != pinDrv
      && !lib.elem name changedOnPurpose then [
      "${name}: nixpkgs changed its ${pinVersion} package, so copy the change into pkgs/."
    ] else [ ]
  ) (builtins.attrNames localPkgs);

  errors = staleFixes ++ outdatedPkgs;
in
if errors != [] then
  throw "Stale packages:\n${lib.concatStringsSep "\n" errors}"
else
  pkgs.runCommand "nix-bitcoin-stale-packages" {} ''
    touch "$out"
  ''
