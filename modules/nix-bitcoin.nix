{ config, options, pkgs, lib, ... }:

with lib;
{
  options = {
    nix-bitcoin = {
      pkgs = mkOption {
        type = types.attrs;
        default = (import ../pkgs { inherit pkgs; }).modulesPkgs;
        defaultText = "nix-bitcoin/pkgs.modulesPkgs";
        description = ''
          The package set of the bitcoinix modules, like `config.nix-bitcoin.pkgs.bitcoind`.
          It holds the packages that bitcoinix builds and the nixpkgs packages it
          selects for its services.
          The flake's NixOS module builds it from the nixpkgs locked by the flake or
          from the system's nixpkgs, see {option}`nix-bitcoin.useVersionLockedPkgs`.
          Without the flake, it comes from the system's nixpkgs.
        '';
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
        description = ''
          Helpers of the bitcoinix modules, defined in `pkgs/lib.nix`. Your own
          modules can use them too, like `config.nix-bitcoin.lib.defaultHardening`,
          the systemd sandboxing settings of most bitcoinix services.
          `defaultHardening` denies all IP traffic. To allow it, also merge
          `allowLocalIPAddresses` or `allowAllIPAddresses`.
          `allowLocalIPAddresses` allows only localhost and, with netns isolation,
          the namespace subnet. It also hides the local name-resolution sockets,
          like those of nscd, systemd-resolved and D-Bus.
        '';
      };

      torClientAddressWithPort = mkOption {
        internal = true;
        readOnly = true;
        default = with config.services.tor.client.socksListenAddress;
          "${addr}:${toString port}";
        defaultText = "(See source)";
      };

      # Torify binary that works with custom Tor SOCKS addresses
      # Related issue: https://github.com/NixOS/nixpkgs/issues/94236
      torify = mkOption {
        internal = true;
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
        internal = true;
        readOnly = true;
        default = if config.security.doas.enable
                  then "doas -u"
                  else "sudo -u";
        defaultText = "(See source)";
      };
    };
  };
}
