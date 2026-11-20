{ config, lib, pkgs, ... }:

with lib;
let
  options.services.rbitcoin-space = {
    enable = mkEnableOption ''
      rbitcoin.space, a block explorer for rbitcoin with a live mempool, blocks,
      mining pages and an Esplora-compatible API.
      It enables {option}`services.rbitcoin` with its JSON-RPC, Electrum and
      Esplora servers and the address index'';
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP server address.";
    };
    port = mkOption {
      type = types.port;
      default = 60847; # A random private port
      description = "HTTP server port.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/rbitcoin-space";
      description = ''
        The explorer's SQLite store: block table, mempool history, replacements.
        It holds only data derived from the node and is rebuilt by the backfill
        when lost.
      '';
    };
    mempool = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to follow the node's mempool, for the live mempool, projected
        blocks and fee recommendations. The tracker polls the node about once a
        second (about 150 MB a minute of RPC traffic on mainnet).
      '';
    };
    broadcast = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether `POST /api/tx` relays transactions to the node. It is the
        explorer's only write to the node.
      '';
    };
    settings = mkOption {
      type = with types; attrsOf (oneOf [ str int bool ]);
      default = { };
      example = {
        BACKFILL_BUSY_PERCENT = 25;
        TRUSTED_PROXY_HEADER = "X-Real-IP";
        TRUSTED_PROXIES = "127.0.0.1";
      };
      description = ''
        Further environment variables, documented in upstream's
        [CONFIG.md](https://github.com/smolcars/rbitcoin-space/blob/v${cfg.package.version}/docs/CONFIG.md).
        The node connection, listener and data directory are set by this module.
        These values are copied to the world-readable Nix store, so they must
        not hold secrets.

        Lightning gossip (`<NET>_LIGHTNING_ENABLED`) and the Ark pages
        (`<NET>_BARK_URL`, `<NET>_ARKADE_URL`) connect to the internet, so they
        fail with {option}`services.rbitcoin-space.tor.enforce`.
      '';
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.rbitcoin-space;
      defaultText = "config.nix-bitcoin.pkgs.rbitcoin-space";
      description = "The package providing the explorer's server and frontend.";
    };
    user = mkOption {
      type = types.str;
      default = "rbitcoin-space";
      description = "The user as which to run rbitcoin.space.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run rbitcoin.space.";
    };
    tor.enforce = nbLib.tor.enforce;
  };

  cfg = config.services.rbitcoin-space;
  nbLib = config.nix-bitcoin.lib;
  rbitcoin = config.services.rbitcoin;

  # The explorer reads each network's settings under its own prefix.
  # rbitcoin's `testnet` is testnet3, which the explorer does not support.
  prefixes = {
    mainnet = "MAINNET";
    signet = "SIGNET";
    regtest = "REGTEST";
  };
  supported = prefixes ? ${rbitcoin.network};
  net = prefixes.${rbitcoin.network} or "UNSUPPORTED";

  # Set by the module, so `settings` must not override them
  managed = [ "LISTEN_ADDR" "DATA_DIR" "BROADCAST_ENABLED" ]
    ++ map (name: "${net}_${name}") [
      "RPC_HOST" "RPC_PORT" "RPC_USER" "RPC_PASSWORD"
      "ESPLORA_URL" "ELECTRUM_ADDR" "MEMPOOL_ENABLED"
    ];

  env = {
    LISTEN_ADDR = bracketed cfg.address cfg.port;
    DATA_DIR = cfg.dataDir;
    BROADCAST_ENABLED = cfg.broadcast;
    # The service runs under systemd, which adds its own timestamps
    LOG_FORMAT = "text";
    "${net}_RPC_HOST" = nbLib.address rbitcoin.rpc.address;
    "${net}_RPC_PORT" = rbitcoin.rpc.port;
    "${net}_ESPLORA_URL" = "http://${hostPort rbitcoin.esplora.address rbitcoin.esplora.port}";
    "${net}_ELECTRUM_ADDR" = hostPort rbitcoin.electrum.address rbitcoin.electrum.port;
    "${net}_MEMPOOL_ENABLED" = cfg.mempool;
  } // cfg.settings;

  # `nbLib.addressWithPort` does not bracket IPv6 addresses.
  # `bracketed` is for the explorer's own listener and keeps a wildcard
  # address. `hostPort` is for connecting to rbitcoin, so it maps a wildcard
  # listen address to loopback.
  bracketed = host: port:
    "${if hasInfix ":" host then "[${host}]" else host}:${toString port}";
  hostPort = addr: bracketed (nbLib.address addr);

  toEnv = v: if isBool v then boolToString v else toString v;

  # The RPC user and password come from rbitcoin's cookie, which rbitcoin
  # replaces on every start. They are read here, at every start of this
  # service, and passed in the environment (readable only by this user),
  # never on the command line or in the Nix store.
  start = pkgs.writers.writeBash "rbitcoin-space-start" ''
    set -euo pipefail
    # The cookie is `user:password` with no trailing newline, so `read`
    # returns 1 at the end of the file even though it read the line.
    IFS=: read -r user password < '${rbitcoin.rpc.cookieFile}' || [[ $password ]]
    export ${net}_RPC_USER=$user ${net}_RPC_PASSWORD=$password
    exec ${getExe cfg.package}
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = supported;
        message = ''
          services.rbitcoin-space supports services.rbitcoin.network mainnet, signet
          and regtest, not ${rbitcoin.network}.
        '';
      }
      { assertion = all (name: !(cfg.settings ? ${name})) managed;
        message = ''
          services.rbitcoin-space.settings must not set ${concatStringsSep ", "
            (filter (name: cfg.settings ? ${name}) managed)}: the module sets these.
          The RPC credentials come from rbitcoin's cookie at runtime; anything in
          `settings` is copied to the world-readable Nix store.
        '';
      }
    ];

    services.rbitcoin = {
      enable = true;
      rpc.enable = true;
      electrum.enable = true;
      esplora.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.rbitcoin-space = {
      description = "rbitcoin.space block explorer";
      # Every rbitcoin start writes a new RPC cookie, and the explorer reads it
      # only at its own start. So it stops and starts with rbitcoin: BindsTo
      # stops it whenever rbitcoin stops (also on a crash), PartOf repeats an
      # explicit restart, and WantedBy rbitcoin starts it with every start of
      # rbitcoin, including an automatic restart after a crash.
      # Not Upholds: it would restart a stopped explorer at once, undoing
      # `systemctl stop` and the stop half of a nixos-rebuild switch.
      wantedBy = [ "multi-user.target" "rbitcoin.service" ];
      bindsTo = [ "rbitcoin.service" ];
      partOf = [ "rbitcoin.service" ];
      after = [ "rbitcoin.service" ];
      environment = mapAttrs (_: toEnv) env;
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = start;
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
        # One descriptor per open socket; it serves up to 1,024 connections
        LimitNOFILE = 65536;
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      # Read rbitcoin's RPC cookie
      extraGroups = [ "rbitcoinrpc" ];
    };
    users.groups.${cfg.group} = {};
  };
}
