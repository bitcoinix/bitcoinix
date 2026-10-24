{ config, lib, pkgs, ... }:

with lib;
let
  options.services.electrs = {
    enable = mkEnableOption "electrs, an Electrum server implemented in Rust";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for RPC connections.";
    };
    port = mkOption {
      type = types.port;
      default = 50001;
      description = "Port to listen for RPC connections.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/electrs";
      description = "The data directory for electrs.";
    };
    monitoringPort = mkOption {
      type = types.port;
      default = 4224;
      description = "Prometheus monitoring port.";
    };
    extraArgs = mkOption {
      type = types.separatedString " ";
      default = "";
      description = "Extra command line arguments passed to electrs.";
    };
    user = mkOption {
      type = types.str;
      default = "electrs";
      description = "The user as which to run electrs.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run electrs.";
    };
    tor.enforce = nbLib.tor.enforce;
  };

  cfg = config.services.electrs;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  bitcoind = config.services.bitcoind;

  # electrs 0.12 keeps its index in the same path as earlier versions but can't
  # read their format. A marker file next to the index identifies a 0.12 index.
  dbPath = "${cfg.dataDir}/${bitcoind.makeNetworkName "bitcoin" "regtest"}";
  bindexMarker = "${dbPath}.bindex";
  # Exit status for an old index, excluded from restarts
  oldIndexStatus = 78;
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = bitcoind.prune == 0;
        message = "electrs does not support bitcoind pruning.";
      }
      { assertion = versionAtLeast config.nix-bitcoin.pkgs.bitcoind.version "31";
        message = "electrs requires Bitcoin Core 31 or later.";
      }
    ];

    services.bitcoind = {
      enable = true;
      # electrs fetches blocks via REST
      rest.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.electrs = {
      # `wantedBy` bitcoind: a deploy that changes the bitcoind unit stops and
      # starts bitcoind. `requires` propagates the stop to this unit, and on
      # production nodes the unit stayed down after such a switch. Being wanted
      # by bitcoind ties this unit's start to bitcoind's own start job, ordered
      # after it. `requires` stays so that an explicit `systemctl stop bitcoind`
      # keeps every dependent down, with no restart that could pull bitcoind
      # back up.
      wantedBy = [ "multi-user.target" "bitcoind.service" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" "nix-bitcoin-secrets.target" ];
      preStart = ''
        # electrs.toml holds the public RPC password, so create it with mode 600
        # instead of relying on the data directory mode alone.
        install -T -m 600 \
          <(echo "auth = \"${bitcoind.rpc.users.public.name}:$(cat ${secretsDir}/bitcoin-rpcpassword-public)\"") \
          electrs.toml
        '';
      serviceConfig = nbLib.defaultHardening // {
        # electrs only uses the working directory for reading electrs.toml
        WorkingDirectory = cfg.dataDir;
        # Check the index in the main process: a failing ExecStartPre isn't
        # covered by RestartPreventExitStatus and would restart every 10s.
        ExecStart = pkgs.writeShellScript "electrs" ''
          if [[ ! -e '${dbPath}' ]]; then
            touch '${bindexMarker}' || exit 1
          elif [[ ! -e '${bindexMarker}' ]]; then
            echo "'${dbPath}' contains an index of electrs < 0.12, which electrs 0.12 can't read."
            echo "Rebuild the index from scratch (this takes hours):"
            echo "  systemctl stop electrs"
            echo "  rm -r '${dbPath}'"
            echo "  systemctl start electrs"
            echo 'See docs/configuration.md, "Upgrading to config version 0.1.2".'
            exit ${toString oldIndexStatus}
          fi
          exec ${config.nix-bitcoin.pkgs.electrs}/bin/electrs \
          --log-filters=INFO \
          --network=${bitcoind.makeNetworkName "bitcoin" "regtest"} \
          --db-dir='${cfg.dataDir}' \
          --daemon-dir='${bitcoind.dataDir}' \
          --electrum-rpc-addr=${cfg.address}:${toString cfg.port} \
          --monitoring-addr=${cfg.address}:${toString cfg.monitoringPort} \
          --daemon-rpc-addr=${nbLib.addressWithPort bitcoind.rpc.address bitcoind.rpc.port} \
          ${cfg.extraArgs}
        '';
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "10s";
        RestartPreventExitStatus = oldIndexStatus;
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "bitcoinrpc-public" ];
    };
    users.groups.${cfg.group} = {};
  };
}
