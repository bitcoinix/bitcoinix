# Fails when the nixpkgs pin has the `fixedIn` version of an entry of
# ../pkgs/security-fixes.nix, so that the entry gets removed
{ pkgs, fixes ? (import ../pkgs/security-fixes.nix).fixes }:
let
  inherit (pkgs) lib;

  staleFixes = lib.concatMap (name: let
    inherit (pkgs.${name}) version;
    inherit (fixes.${name}) fixedIn;
  in lib.optional (lib.versionAtLeast version fixedIn)
    "${name}: nixpkgs has ${version}, so remove its entry (fixedIn ${fixedIn}) from pkgs/security-fixes.nix."
  ) (builtins.attrNames fixes);
in
if staleFixes != [] then
  throw "Stale security fixes:\n${lib.concatStringsSep "\n" staleFixes}"
else
  pkgs.runCommand "nix-bitcoin-stale-packages" {} ''
    touch "$out"
  ''
