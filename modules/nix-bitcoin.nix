{ config, options, pkgs, lib, ... }:

with lib;
{
  options = {
    bitcoinix = {
      pkgs = mkOption {
        type = types.attrs;
        default = (import ../pkgs { inherit pkgs; }).modulesPkgs;
        defaultText = "nix-bitcoin/pkgs.modulesPkgs";
        description = ''
          The packages that the bitcoinix services run: the packages defined in
          {file}`pkgs/` and the service packages selected from nixpkgs.
          Refer to a package as `config.nix-bitcoin.pkgs.<name>`, e.g.
          `config.nix-bitcoin.pkgs.bitcoind`.
        '';
        apply = base:
          let
            final = foldl (prev: overlay:
              prev // (overlay prev final)
            ) base options.bitcoinix.pkgOverlays.definitions;
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
          Helpers shared by the bitcoinix modules, defined in
          {file}`pkgs/lib.nix`. `defaultHardening` holds the systemd sandboxing
          settings that most bitcoinix services run with. They deny all IP
          traffic, so merge them with `allowLocalIPAddresses` or
          `allowAllIPAddresses` for a service that needs the network:
          ```nix
          systemd.services.<name>.serviceConfig = with config.nix-bitcoin.lib;
            defaultHardening // allowLocalIPAddresses;
          ```
          `allowLocalIPAddresses` allows localhost and, with netns-isolation,
          the namespace addresses `169.254.<addressblock>.0/24`. It also hides
          the nscd, systemd-resolved and D-Bus sockets (and Avahi's, when
          enabled) from the service, so it
          resolves names only from {file}`/etc/hosts` or through a resolver on
          an allowed address.
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
