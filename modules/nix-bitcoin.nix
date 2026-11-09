{ config, options, pkgs, lib, ... }:

with lib;
{
  options = {
    nix-bitcoin = {
      pkgs = mkOption {
        type = types.attrs;
        default = (import ../pkgs { inherit pkgs; }).modulesPkgs;
        defaultText = "nix-bitcoin/pkgs.modulesPkgs";
        apply = base:
          let
            final = foldl (prev: overlay:
              prev // (overlay prev final)
            ) base options.nix-bitcoin.pkgOverlays.definitions;
          in
            final;
      };

      pkgOverlays = mkOption {
        internal = true;
        type = with types; functionTo attrs;
        example = lib.literalExpression ''
          super: self: {
            bitcoind = super.bitcoind.overrideAttrs (old: {
              # dostuff
            });
          }
        '';
      };

      revision = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "6d209ffe17e13abe15f5d368e18f14436019d317";
        description = ''
          The bitcoinix git commit that this system is built from.
          `nixosModules.default` of the bitcoinix flake sets this to the flake's
          revision (`<rev>-dirty` for a checkout with uncommitted changes).
          It is `null` when the flake source has no revision or when the modules
          are imported without the flake.
          Shown by {command}`nodeinfo`.
        '';
      };

      lib = mkOption {
        readOnly = true;
        default = import ../pkgs/lib.nix lib pkgs config;
        defaultText = "nix-bitcoin/pkgs/lib.nix";
      };

      torClientAddressWithPort = mkOption {
        readOnly = true;
        default = with config.services.tor.client.socksListenAddress;
          "${addr}:${toString port}";
        defaultText = "(See source)";
      };

      # Torify binary that works with custom Tor SOCKS addresses
      # Related issue: https://github.com/NixOS/nixpkgs/issues/94236
      torify = mkOption {
        readOnly = true;
        default = pkgs.writers.writeBashBin "torify" ''
          ${pkgs.tor}/bin/torify \
            --address ${config.services.tor.client.socksListenAddress.addr} \
            "$@"
        '';
        defaultText = "(See source)";
      };

      # A helper for using doas instead of sudo when doas is enabled
      runAsUserCmd = mkOption {
        readOnly = true;
        default = if config.security.doas.enable
                  then "doas -u"
                  else "sudo -u";
        defaultText = "(See source)";
      };
    };
  };
}
