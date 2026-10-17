{ config, lib, pkgs, ... }:

with lib;
let
  options.services.rbitcoin = {
    enable = mkEnableOption ''
      rbitcoin, an experimental Bitcoin full node in Rust with built-in
      Electrum and Esplora servers.
      rbitcoin keeps its own archive format and cannot share a data directory
      with bitcoind'';
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.rbitcoin;
      defaultText = "config.nix-bitcoin.pkgs.rbitcoin";
      description = "The rbitcoin package to use.";
    };
    network = mkOption {
      type = types.enum [ "mainnet" "testnet" "signet" "regtest" ];
      default = "mainnet";
      description = "The network to sync.";
    };
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for peer connections.";
    };
    port = mkOption {
      type = types.port;
      default = defaultPorts.${cfg.network}.p2p;
      defaultText = "8333 for mainnet, the network's default port otherwise";
      description = "Port to listen for peer connections.";
    };
    listen = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to accept incoming peer connections.";
    };
    connect = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "127.0.0.1:18444" ];
      description = ''
        Peers (`host:port`) to connect to exclusively. When set, rbitcoin makes
        no other outbound connections.
      '';
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/rbitcoin";
      description = "The data directory for rbitcoin.";
    };
    coldDataDir = mkOption {
      type = with types; nullOr path;
      default = null;
      description = ''
        Optional second data directory for the large, rarely read witness
        archive (several hundred GiB on mainnet), so it can live on slower
        storage.
      '';
    };
    milestone = mkOption {
      type = with types; nullOr ints.u32;
      default = null;
      description = ''
        Height below which script validation is skipped (comparable to
        bitcoind's `assumevalid`). `null` keeps rbitcoin's anchored default.
        `0` validates every script. Changing this after the initial sync
        requires a new data directory.
      '';
    };
    shIndex = mkOption {
      type = types.bool;
      default = cfg.electrum.enable;
      defaultText = "config.services.rbitcoin.electrum.enable";
      description = ''
        Whether to build the scripthash (address) index, which the Electrum
        and Esplora address methods require. It is built once the node
        reaches the tip; on mainnet this takes several hours.
      '';
    };
    maxShCreates = mkOption {
      type = types.ints.u32;
      default = 10000;
      description = ''
        Refuse unpaged address-history and balance queries for scripts with
        more than this many outputs. Each such query loads every output, so
        the cap bounds the cost of a single unauthenticated Electrum request.
        `0` means no cap.
      '';
    };
    rpc = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to serve the Bitcoin Core compatible JSON-RPC subset over TCP.
          Clients authenticate with an RPC cookie at `cookieFile`, readable by
          group `rbitcoinrpc`. The unix socket in `dataDir` is always enabled
          for the `rbitcoin-cli` wrapper.
        '';
      };
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen for JSON-RPC connections.";
      };
      port = mkOption {
        type = types.port;
        default = defaultPorts.${cfg.network}.rpc;
        defaultText = "8332 for mainnet, the network's default port otherwise";
        description = "Port to listen for JSON-RPC connections.";
      };
      cookieFile = mkOption {
        readOnly = true;
        type = types.path;
        default = "/run/rbitcoin/rpc.cookie";
        description = ''
          Bitcoin Core format RPC cookie, regenerated on every start. Clients
          should read it from this path (and re-read it after an HTTP 401)
          rather than copy it.
        '';
      };
    };
    electrum = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to serve the Electrum protocol (plain TCP). The listener only
          opens once the scripthash index has caught up with the tip.
        '';
      };
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen for Electrum connections.";
      };
      port = mkOption {
        type = types.port;
        default = 50001;
        description = "Port to listen for Electrum connections.";
      };
    };
    logLevel = mkOption {
      type = types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level.";
    };
    extraArgs = mkOption {
      type = with types; listOf str;
      default = [ ];
      description = "Extra command line arguments passed to rbitcoin-node.";
    };
    user = mkOption {
      type = types.str;
      default = "rbitcoin";
      description = "The user as which to run rbitcoin.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run rbitcoin.";
    };
    cli = mkOption {
      readOnly = true;
      type = types.package;
      default = pkgs.writers.writeBashBin "rbitcoin-cli" ''
        exec ${cfg.package}/bin/rbitcoin-cli --network ${cfg.network} \
          --rpc-socket '${cfg.dataDir}/rpc.sock' "$@"
      '';
      defaultText = "(See source)";
      description = "Binary to connect with the rbitcoin instance.";
    };
    tor = nbLib.tor;
  };

  cfg = config.services.rbitcoin;
  nbLib = config.nix-bitcoin.lib;

  defaultPorts = {
    mainnet = { p2p = 8333; rpc = 8332; };
    testnet = { p2p = 18333; rpc = 18332; };
    signet = { p2p = 38333; rpc = 38332; };
    regtest = { p2p = 18444; rpc = 18443; };
  };

  # A bind address, kept as configured (`nbLib.addressWithPort` would turn
  # 0.0.0.0 into 127.0.0.1, which is right for clients but not for listeners).
  listenAddress = addr: port:
    "${if hasInfix ":" addr then "[${addr}]" else addr}:${toString port}";

  torSocket = config.services.tor.client.socksListenAddress;

  # Listeners that must not share a socket with rbitcoin's (for setups without
  # netns isolation, where every service binds 127.0.0.1 by default).
  wildcards = [ "0.0.0.0" "::" ];
  sameSocket = a: b:
    a.port == b.port
    && (a.address == b.address || elem a.address wildcards || elem b.address wildcards);
  collision = name: mine: other: otherName: {
    assertion = !(sameSocket mine other);
    message = ''
      services.rbitcoin.${name} (${listenAddress mine.address mine.port}) collides
      with ${otherName} (${listenAddress other.address other.port}). Set a different port.
    '';
  };
  inherit (config.services) bitcoind electrs fulcrum;
  isUnder = dir: path: path == dir || hasPrefix "${dir}/" path;

  args = [
    "--datadir=${cfg.dataDir}"
    "--network=${cfg.network}"
    "--log-level=${cfg.logLevel}"
  ]
  ++ (if cfg.listen
      then [ "--listen=${listenAddress cfg.address cfg.port}" ]
      else [ "--no-listen" ])
  ++ concatMap (peer: [ "--connect" peer ]) cfg.connect
  ++ optional (cfg.coldDataDir != null) "--datadir-cold=${cfg.coldDataDir}"
  ++ optional (cfg.milestone != null) "--milestone=${toString cfg.milestone}"
  ++ optionals cfg.shIndex [ "--sh-index" "--max-sh-creates=${toString cfg.maxShCreates}" ]
  # Always serve the unix socket, used by `cfg.cli`. Naming its path makes
  # rbitcoin create it with mode 0660, so group `cfg.group` (the operator)
  # can connect.
  ++ [ "--rpc" "--rpc-socket=${cfg.dataDir}/rpc.sock" ]
  ++ optionals cfg.rpc.enable [
    "--rpc-listen=${listenAddress cfg.rpc.address cfg.rpc.port}"
    "--rpc-cookie-file=${cfg.rpc.cookieFile}"
  ]
  ++ optional cfg.electrum.enable "--electrum-listen=${listenAddress cfg.electrum.address cfg.electrum.port}"
  # Seed hostnames go to the proxy too; rbitcoin never resolves them locally
  # while a proxy is set.
  ++ optionals cfg.tor.proxy [
    "--proxy=${torSocket.addr}:${toString torSocket.port}"
    "--onion=${torSocket.addr}:${toString torSocket.port}"
  ]
  ++ cfg.extraArgs;
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = !cfg.electrum.enable || cfg.shIndex;
        message = "services.rbitcoin.electrum requires services.rbitcoin.shIndex.";
      }
      { assertion = all (dir: !(isUnder bitcoind.dataDir dir || isUnder dir bitcoind.dataDir))
          ([ cfg.dataDir ] ++ optional (cfg.coldDataDir != null) cfg.coldDataDir);
        message = ''
          services.rbitcoin.dataDir and coldDataDir must not contain, or be inside,
          services.bitcoind.dataDir: rbitcoin cannot read bitcoind's blocks.
        '';
      }
    ]
    ++ optionals bitcoind.enable (
      optional cfg.rpc.enable
        (collision "rpc.port" cfg.rpc bitcoind.rpc "services.bitcoind.rpc.port")
      ++ optional (cfg.listen && bitcoind.listen)
      (collision "port" cfg bitcoind "services.bitcoind.port"))
    ++ optional (cfg.electrum.enable && electrs.enable)
      (collision "electrum.port" cfg.electrum electrs "services.electrs.port")
    ++ optional (cfg.electrum.enable && fulcrum.enable)
      (collision "electrum.port" cfg.electrum fulcrum "services.fulcrum.port");

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ] ++ optional (cfg.coldDataDir != null)
      "d '${cfg.coldDataDir}' 0750 ${cfg.user} ${cfg.group} - -";

    systemd.services.rbitcoin = {
      description = "rbitcoin Bitcoin full node";
      wantedBy = [ "multi-user.target" ];
      # A local bitcoind is the usual `connect` peer
      after = [ "network.target" ] ++ optional bitcoind.enable "bitcoind.service";
      unitConfig.RequiresMountsFor = [ cfg.dataDir ] ++ optional (cfg.coldDataDir != null) cfg.coldDataDir;
      serviceConfig = nbLib.defaultHardening // {
        # The cookie is written here instead of being a nix-bitcoin secret so
        # that it exists only at runtime and changes on every start. Mode 0640
        # and no trailing newline, as Bitcoin Core writes it (clients send the
        # contents verbatim as HTTP Basic credentials). Runs as root (`+`):
        # `PrivateUsers` would hide group `rbitcoinrpc` from the service.
        ExecStartPre = mkIf cfg.rpc.enable (nbLib.rootScript "rbitcoin-rpc-cookie" ''
          cookie='${cfg.rpc.cookieFile}'
          tmp=$(mktemp "$cookie.XXXXXX")
          printf '__cookie__:%s' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$tmp"
          chown ${cfg.user}:rbitcoinrpc "$tmp"
          chmod 0640 "$tmp"
          mv -f "$tmp" "$cookie"
        '');
        ExecStart = "${cfg.package}/bin/rbitcoin-node ${escapeShellArgs args}";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "rbitcoin";
        # Group `rbitcoinrpc` reaches the cookie through this directory,
        # without being able to list it.
        RuntimeDirectoryMode = "0711";
        Restart = "on-failure";
        RestartSec = "10s";
        # On shutdown the node flushes its tip tables and mempool.
        TimeoutStopSec = "15min";
        LimitNOFILE = 65536;
        ReadWritePaths = [ cfg.dataDir ] ++ optional (cfg.coldDataDir != null) cfg.coldDataDir;
        # The store sizes its caches from /proc/meminfo, which `ProcSubset=pid`
        # hides.
        ProcSubset = "all";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};
    users.groups.rbitcoinrpc = {};
    nix-bitcoin.operator.groups = [ cfg.group ];
  };
}
