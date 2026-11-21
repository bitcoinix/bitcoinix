# Urgent security fixes for packages of the nixpkgs pin.
#
# Each entry replaces the nixpkgs package of the same name with `package` while
# the pin's version is older than `fixedIn`. Once nixpkgs has `fixedIn` or newer,
# the entry falls back to the nixpkgs package, and the `stale-packages` flake check
# fails until the entry is removed.
# See ../docs/configuration.md#security-fixes-for-nixpkgs-packages.
let
  fixes = {
    # CVE-2026-56113, CVE-2026-56114, CVE-2026-56116, CVE-2026-56117
    # https://github.com/NixOS/nixpkgs/pull/591315
    # 10.5.1 and later need the unit fix in ../modules/security-fixes.nix.
    dhcpcd = {
      fixedIn = "10.5.2";
      package = prev: prev.dhcpcd.overrideAttrs {
        version = "10.5.2";
        src = prev.fetchFromGitHub {
          owner = "NetworkConfiguration";
          repo = "dhcpcd";
          tag = "v10.5.2";
          hash = "sha256-lrV6SaB/HmTptZigZ1Lf28eUPz0igxyT6omZwXDSuGM=";
        };
      };
    };
  };
in {
  inherit fixes;

  overlay = final: prev: builtins.mapAttrs (name: fix:
    if prev.lib.versionAtLeast prev.${name}.version fix.fixedIn
    then prev.${name}
    else fix.package prev
  ) fixes;
}
