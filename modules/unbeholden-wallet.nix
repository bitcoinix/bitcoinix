{ config, lib, ... }:

with lib;
let
  options.services.unbeholden-wallet = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable Unbeholden Wallet, a watch-only Bitcoin wallet that runs in the
        browser and hands transactions to an air-gapped signer.

        The service serves the wallet and relays its WebSocket connection at
        `/electrum` to the Electrum server set by
        {option}`services.unbeholden-wallet.electrumServer`.

        Browsers only allow the camera, which scans signed transactions,
        on `localhost` or over https. For access from other devices, put an https
        reverse proxy in front of the service.
      '';
    };
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP server address.";
    };
    port = mkOption {
      type = types.port;
      default = 60846; # A random private port
      description = "HTTP server port.";
    };
    electrumServer = mkOption {
      type = types.enum [ "electrs" "fulcrum" ];
      default = "electrs";
      description = ''
        The Electrum server that the wallet connects to.

        Possible options:
        - electrs:
          Small database size, slow when querying new addresses.
        - fulcrum:
          Large database size, quickly serves arbitrary address queries.
      '';
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.unbeholden-wallet;
      defaultText = "config.nix-bitcoin.pkgs.unbeholden-wallet";
      description = "The package providing the wallet and its server.";
    };
    user = mkOption {
      type = types.str;
      default = "unbeholden-wallet";
      description = "The user as which to run Unbeholden Wallet.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run Unbeholden Wallet.";
    };
  };

  cfg = config.services.unbeholden-wallet;
  nbLib = config.nix-bitcoin.lib;
  electrumServer = config.services.${cfg.electrumServer};
in {
  inherit options;

  config = mkIf cfg.enable {
    services.electrs.enable = mkIf (cfg.electrumServer == "electrs") true;
    services.fulcrum.enable = mkIf (cfg.electrumServer == "fulcrum") true;

    systemd.services.unbeholden-wallet = rec {
      wantedBy = [ "multi-user.target" ];
      wants = [ "${cfg.electrumServer}.service" ];
      after = wants;
      environment = {
        HOST = cfg.address;
        PORT = toString cfg.port;
        ELECTRUM = nbLib.addressWithPort electrumServer.address electrumServer.port;
      };
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = getExe cfg.package;
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "10s";
      } // nbLib.allowLocalIPAddresses
        # Bun's JIT needs the same exemptions as Node's
        // nbLib.nodejs;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};
  };
}
