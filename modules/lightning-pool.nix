{ config, lib, pkgs, ... }:

with lib;
let
  options.services.lightning-pool = {
    enable = mkEnableOption "Lightning Pool, a marketplace for inbound lightning liquidity ";
    rpcAddress = mkOption {
       type = types.str;
       default = "127.0.0.1";
       description = "Address to listen for gRPC connections.";
    };
    rpcPort = mkOption {
       type = types.port;
       default = 12010;
       description = "Port to listen for gRPC connections.";
    };
    restAddress = mkOption {
       type = types.str;
       default = cfg.rpcAddress;
       description = "Address to listen for REST connections.";
    };
    restPort = mkOption {
       type = types.port;
       default = 8281;
       description = "Port to listen for REST connections.";
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.lightning-pool;
      defaultText = "config.nix-bitcoin.pkgs.lightning-pool";
      description = "The package providing lightning-pool binaries.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lightning-pool";
      description = "The data directory for lightning-pool.";
    };
    proxy = mkOption {
      type = types.nullOr types.str;
      default = if cfg.tor.proxy then config.nix-bitcoin.torClientAddressWithPort else null;
      description = "host:port of SOCKS5 proxy for connnecting to the pool auction server.";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        debuglevel=trace
      '';
      description = "Extra lines appended to the configuration file.";
    };
    cli = mkOption {
      default = pkgs.writers.writeBashBin "pool" ''
        exec ${cfg.package}/bin/pool \
          --rpcserver ${nbLib.addressWithPort cfg.rpcAddress cfg.rpcPort} \
          --network ${network} \
          --basedir '${cfg.dataDir}' "$@"
      '';
      defaultText = "(See source)";
      description = "Binary to connect with the lightning-pool instance.";
    };
    tor = nbLib.tor;
  };

  cfg = config.services.lightning-pool;
  nbLib = config.nix-bitcoin.lib;

  lnd = config.services.lnd;

  network = config.services.bitcoind.network;
  configFile = builtins.toFile "pool.conf" ''
    rpclisten=${cfg.rpcAddress}:${toString cfg.rpcPort}
    restlisten=${cfg.restAddress}:${toString cfg.restPort}
    ${optionalString (cfg.proxy != null) "proxy=${cfg.proxy}"}

    lnd.host=${lnd.rpcAddress}:${toString lnd.rpcPort}
    lnd.macaroondir=${lnd.networkDir}
    lnd.tlspath=${lnd.certPath}

    ${cfg.extraConfig}
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    services.lnd.enable = true;

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 lnd lnd - -"
    ];

    systemd.services.lightning-pool = {
      wantedBy = [ "multi-user.target" ];
      # `wants`, not `requires`: with `requires`, every lnd stop/start (e.g. a
      # deploy that touches lnd.conf) stopped poold for good. While lnd is
      # down, poold exits and comes back through `Restart = "always"`
      # below; the `lnd-restart-dependents` test checks that it is back up. `after`
      # still orders it behind lnd at boot.
      wants = [ "lnd.service" ];
      after = [ "lnd.service" ];
      preStart = ''
        mkdir -p '${cfg.dataDir}/${network}'
        ln -sfn ${configFile} '${cfg.dataDir}/${network}/poold.conf'
      '';
      serviceConfig = nbLib.defaultHardening // {
        # TODO: temporary sleep to prevent race condition
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        ExecStart = "${cfg.package}/bin/poold --basedir='${cfg.dataDir}' --network=${network}";
        User = "lnd";
        # `always`: the daemon must come back whenever it exits on its own.
        # When lnd goes away, poold shuts down cleanly with status 0, which
        # `on-failure` does not restart, so it stayed down until a manual start.
        Restart = "always";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
      } // (nbLib.allowedIPAddresses cfg.tor.enforce)
        // nbLib.allowNetlink; # required by gRPC-Go
    };
  };
}
