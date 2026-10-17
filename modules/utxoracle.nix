{ config, lib, pkgs, ... }:

with lib;
let
  options.services.utxoracle = with types; {
    enable = mkEnableOption ''
      UTXOracle, a bitcoin price oracle that uses only confirmed blocks from
      your node. Not free software: see the UTXOracle section in
      `docs/services.md` for the license terms and how to allow the package
    '';

    mode = mkOption {
      type = enum [ "consensus" "blockWindow" ];
      default = "consensus";
      description = ''
        - `consensus`: compute the "UTXOracle Consensus Price", the average
          price of the last full UTC day.
        - `blockWindow`: compute the "UTXOracle Block Window Price", the price
          over the most recent 144 confirmed blocks.
      '';
    };

    interval = mkOption {
      type = str;
      default = if cfg.mode == "consensus" then "*-*-* 03:00:00 UTC" else "hourly";
      defaultText = literalExpression ''if mode == "consensus" then "*-*-* 03:00:00 UTC" else "hourly"'';
      description = ''
        Systemd calendar expression when to compute the price.
        See {man}`systemd.time(7)` for possible values.

        The license forbids updates more frequent than once per block, so don't
        set this to run more often than every 10 minutes.

        In `consensus` mode, UTXOracle computes the last full UTC day before
        the block 6 below the tip. So it computes yesterday only once at least
        7 blocks were mined after UTC midnight, and the day before otherwise.
        By 03:00 UTC that's the case on about 99.9% of days, so the
        default runs then.
      '';
    };

    dataDir = mkOption {
      type = path;
      default = "/var/lib/utxoracle";
      description = ''
        The data directory for UTXOracle.
        Each run writes its result as a chart to an HTML file in this directory.
        In `consensus` mode, the price is also written to the journal of
        `utxoracle.service`.
      '';
    };

    outputMaxAge = mkOption {
      type = nullOr str;
      default = if cfg.mode == "blockWindow" then "30d" else null;
      defaultText = literalExpression ''if mode == "blockWindow" then "30d" else null'';
      example = "1y";
      description = ''
        Delete files and directories in `dataDir` that are older than this.
        `null` keeps them forever.
        This applies to everything in `dataDir`, so keep it a directory used
        only by UTXOracle.
        See the age field in {man}`tmpfiles.d(5)` for possible values.

        In `blockWindow` mode, each run writes a new chart, so `dataDir` grows
        by one file per `interval`.
      '';
    };

    user = mkOption {
      type = str;
      default = "utxoracle";
      description = "The user as which to run UTXOracle.";
    };

    group = mkOption {
      type = str;
      default = cfg.user;
      description = "The group as which to run UTXOracle.";
    };

    package = mkOption {
      type = package;
      default = config.nix-bitcoin.pkgs.utxoracle;
      defaultText = "config.nix-bitcoin.pkgs.utxoracle";
      description = "The package providing UTXOracle.";
    };
  };

  cfg = config.services.utxoracle;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  bitcoind = config.services.bitcoind;
in {
  inherit options;

  config = mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      rpc.users.utxoracle = {
        passwordHMACFromFile = true;
        # The RPC calls that UTXOracle.py makes
        rpcwhitelist = [
          "getblock"
          "getblockcount"
          "getblockhash"
          "getblockheader"
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} ${if cfg.outputMaxAge == null then "-" else cfg.outputMaxAge} -"
    ];

    systemd.services.utxoracle = {
      description = "Compute the UTXOracle price from confirmed blocks";
      documentation = [ "https://utxo.live/oracle/" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" "nix-bitcoin-secrets.target" ];
      # UTXOracle.py reads its RPC settings from `bitcoin.conf` in the dir given by `-p`.
      # Create one that only contains the RPC settings for user `utxoracle`.
      preStart = ''
        install -m 600 /dev/null "$RUNTIME_DIRECTORY/bitcoin.conf"
        {
          echo "rpcuser=${bitcoind.rpc.users.utxoracle.name}"
          echo "rpcpassword=$(cat ${secretsDir}/bitcoin-rpcpassword-utxoracle)"
          echo "rpcconnect=${bitcoind.rpc.address}"
          echo "rpcport=${toString bitcoind.rpc.port}"
        } > "$RUNTIME_DIRECTORY/bitcoin.conf"
      '';
      # UTXOracle.py opens its HTML output in a browser.
      # This turns that into a no-op without changing the script.
      environment.BROWSER = "${pkgs.coreutils}/bin/true";
      serviceConfig = nbLib.defaultHardening // {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "utxoracle";
        RuntimeDirectoryMode = "700";
        # UTXOracle.py writes its HTML output to the working dir
        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [ cfg.dataDir ];
        ExecStart = "${cfg.package}/bin/utxoracle -p %t/utxoracle${optionalString (cfg.mode == "blockWindow") " -rb"}";
      } // nbLib.allowLocalIPAddresses;
    };

    systemd.timers.utxoracle = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets = {
      bitcoin-rpcpassword-utxoracle = {
        user = bitcoind.user;
        group = cfg.group;
      };
      bitcoin-HMAC-utxoracle.user = bitcoind.user;
    };
    nix-bitcoin.generateSecretsCmds.utxoracle = ''
      makeBitcoinRPCPassword utxoracle
    '';
  };
}
