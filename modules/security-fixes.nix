{ config, options, lib, pkgs, ... }:

with lib;
let
  cfg = config.nix-bitcoin.securityFixes;
  inherit (import ../pkgs/security-fixes.nix) fixes overlay;

  missingFixes = filter (name: versionOlder pkgs.${name}.version fixes.${name}.fixedIn)
    (attrNames fixes);
  # nixpkgs' read-only module (nixos/modules/misc/nixpkgs/read-only.nix) uses
  # `nixpkgs.pkgs` as given and rejects overlays from other modules
  readOnlyPkgs = options.nixpkgs.overlays.type.name == "unique";

  # As in nixpkgs' dhcpcd module
  dhcpcdEnabled = config.networking.dhcpcd.enable && (config.networking.useDHCP
    || any (i: i.useDHCP == true) (attrValues config.networking.interfaces));
in {
  options.nix-bitcoin.securityFixes.enable = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Apply the urgent security fixes of {file}`pkgs/security-fixes.nix` to the
      system's nixpkgs and to {option}`nix-bitcoin.pkgs`. Each fix replaces a
      nixpkgs package until nixpkgs has the fixed version.
    '';
  };

  config = mkMerge [
    # After the system's other overlays, including those with `mkAfter` (order 1500),
    # so that none of them brings back an unfixed package. One with a later order can,
    # and the warning below names it as a cause.
    (mkIf (cfg.enable && !readOnlyPkgs) {
      nixpkgs.overlays = mkOrder 2000 [ overlay ];
    })

    (mkIf (cfg.enable && missingFixes != []) {
      warnings = [ ''
        The system's pkgs lack the bitcoinix security fixes for ${concatStringsSep ", " missingFixes}.
        This happens when they don't take `nixpkgs.overlays`, as with a read-only
        `nixpkgs.pkgs` or with `pkgs` set through `specialArgs`, or when an overlay that
        runs later replaces these packages. Add the fixes to your pkgs
        with overlay `securityFixes` of the bitcoinix flake, or without flakes with
        `(import <nix-bitcoin/pkgs/security-fixes.nix>).overlay`. To run without the fixes,
        set `nix-bitcoin.securityFixes.enable = false`.
      '' ];
    })

    # dhcpcd 10.5.1 and later chown their control socket, which the unit's
    # `~@privileged` filter denies. This applies to any such dhcpcd, ours or the pin's.
    # Remove it once the pin's dhcpcd module allows `@chown` itself.
    (mkIf (dhcpcdEnabled && versionAtLeast pkgs.dhcpcd.version "10.5.1") {
      systemd.services.dhcpcd.serviceConfig.SystemCallFilter = mkAfter [ "@chown" ];
    })
  ];
}
