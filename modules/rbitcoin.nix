{ config, lib, pkgs, utils, ... }:

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
          group `rbitcoinrpc`. The cookie appears there only once rbitcoin
          listens on the RPC port, which is after it has caught up with the
          chain. The unix socket in `dataDir` is always enabled for the
          `rbitcoin-cli` wrapper.

          WARNING: The cookie is an administrative credential. rbitcoin has
          no restricted or read-only credential, so every method (including
          `stop` and `invalidateblock`) is available to anyone who can read
          it. Do not add services you do not trust to group `rbitcoinrpc`.
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
      portOwnedBy = mkOption {
        internal = true;
        readOnly = true;
        default = rpcPortOwnedBy;
        description = ''
          Script that exits 0 if the process with the given pid owns the RPC
          port. Used by `rbitcoin-rpc-cookie` and the tests.
        '';
      };
      cookieFile = mkOption {
        readOnly = true;
        type = types.path;
        default = "/run/rbitcoin-rpc/rpc.cookie";
        description = ''
          Bitcoin Core format RPC cookie, regenerated on every start. It exists
          only while rbitcoin holds its RPC port, so a client that finds it
          talks to rbitcoin and not to another local process that took the
          port while rbitcoin was still syncing. Clients should wait for it,
          read it from this path (and re-read it after an HTTP 401) rather
          than copy it.
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

  # rbitcoin reads its RPC cookie when it opens the RPC port, after catch-up,
  # which can be days after the start. Until then any local user can listen
  # on that port, so a client must not send the cookie before rbitcoin holds
  # it. rbitcoin's copy is in its 0700 runtime directory. root keeps a second
  # copy (`pendingCookie`), and `rbitcoin-rpc-cookie` publishes it at
  # `cfg.rpc.cookieFile` while rbitcoin's main process owns the RPC port.
  nodeCookie = "/run/rbitcoin/rpc.cookie";
  pendingCookie = "/run/rbitcoin-rpc.pending";

  # The listeners that take a client's connection to the RPC address: that
  # address and the wildcards. `ss` prints IPv6 addresses in brackets and a
  # dual-stack wildcard as `*`.
  rpcClientAddress = nbLib.address cfg.rpc.address;
  rpcPort = toString cfg.rpc.port;
  rpcListeners = [ "${listenAddress rpcClientAddress cfg.rpc.port}" "[::]:${rpcPort}" "*:${rpcPort}" ]
    ++ optionals (!hasInfix ":" rpcClientAddress) [
      "0.0.0.0:${rpcPort}"
      "[::ffff:${rpcClientAddress}]:${rpcPort}"
    ];

  # Exits 0 if the process with pid $1 owns all listeners in `rpcListeners`,
  # and there is at least one. Sockets are matched by inode against the
  # process's open files. Process names are not used: `ss -p` prints them
  # unescaped, and any user can name a process `pid=<pid>,`.
  rpcPortOwnedBy = pkgs.writers.writeBash "rbitcoin-rpc-port-owned-by" ''
    set -euo pipefail
    pid=$1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || exit 1
    # The inodes of the process's open sockets, in one pass: rbitcoin keeps
    # thousands of files open
    inodes=" $(${pkgs.findutils}/bin/find /proc/"$pid"/fd -mindepth 1 -printf '%l\n' 2>/dev/null \
      | ${pkgs.gnused}/bin/sed -n 's/^socket:\[\([0-9]*\)\]$/\1/p' | ${pkgs.coreutils}/bin/tr '\n' ' ') "
    # Only the first `ino:` field: later fields like `cgroup:` hold names
    # that users choose
    ${pkgs.iproute2}/bin/ss -Hltne 'sport = :${rpcPort}' \
      | ${pkgs.gawk}/bin/awk -v mine="$inodes" -v listeners='${concatStringsSep " " rpcListeners}' '
          BEGIN { n = split(listeners, l, " "); for (i = 1; i <= n; i++) relevant[l[i]] = 1 }
          !($4 in relevant) { next }
          {
            found = 1; ino = ""
            for (i = 5; i <= NF; i++) if ($i ~ /^ino:/) { ino = substr($i, 5); break }
            if (ino == "" || index(mine, " " ino " ") == 0) other = 1
          }
          END { exit !(found && !other) }'
  '';

  publishCookie = nbLib.script "rbitcoin-rpc-cookie-publish" ''
    pid=$(${config.systemd.package}/bin/systemctl show -P MainPID rbitcoin.service)
    if [[ ! $pid =~ ^[1-9][0-9]*$ ]]; then
      echo "rbitcoin has no main process"
      exit 1
    fi
    owned() { ${rpcPortOwnedBy} "$pid"; }
    if ! owned; then
      echo "Waiting for rbitcoin to listen on ${concatStringsSep ", " rpcListeners}"
      until owned; do sleep 2; done
    fi
    install -m 0640 -g rbitcoinrpc '${pendingCookie}' '${cfg.rpc.cookieFile}.tmp'
    mv -fT '${cfg.rpc.cookieFile}.tmp' '${cfg.rpc.cookieFile}'
    echo "Published the RPC cookie at ${cfg.rpc.cookieFile}"
    # Keep watching: rbitcoin may restart between the check and the move, or
    # lose its listener while it keeps running. Exiting removes the runtime
    # directory and the cookie with it, and the unit restarts and waits again.
    while owned; do sleep 5; done
    echo "rbitcoin no longer holds its RPC port, removing the cookie"
    rm -f '${cfg.rpc.cookieFile}'
    exit 1
  '';
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
    "--rpc-cookie-file=${nodeCookie}"
    # rbitcoin's own copy is 0600 (see ExecStartPre). Clients read the
    # published copy, see `nodeCookie`.
    "--rpc-cookie-perms" "owner"
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
        # that it exists only at runtime and changes on every start. No
        # trailing newline, as Bitcoin Core writes it (clients send the
        # contents verbatim as HTTP Basic credentials). Runs as root (`+`) to
        # keep the copy that `rbitcoin-rpc-cookie` publishes, see `nodeCookie`.
        ExecStartPre = mkIf cfg.rpc.enable (nbLib.rootScript "rbitcoin-rpc-cookie" ''
          cookie='${nodeCookie}'
          # /run/rbitcoin belongs to the service user, who could swap a file
          # there for a symlink between root's write and its chown/chmod. Build
          # the cookie in a root-only directory and only rename it into place.
          dir=$(mktemp -d /run/rbitcoin-cookie.XXXXXX)
          trap 'rm -rf "$dir"' EXIT
          secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
          [[ ''${#secret} == 64 ]]
          printf '__cookie__:%s' "$secret" > "$dir/cookie"
          install -m 0600 "$dir/cookie" '${pendingCookie}'
          chown ${cfg.user}:${cfg.group} "$dir/cookie"
          chmod 0600 "$dir/cookie"
          mv -fT "$dir/cookie" "$cookie"
        '');
        ExecStart = "${cfg.package}/bin/rbitcoin-node ${utils.escapeSystemdExecArgs args}";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "rbitcoin";
        RuntimeDirectoryMode = "0700";
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

    systemd.services.rbitcoin-rpc-cookie = mkIf cfg.rpc.enable {
      description = "Publish rbitcoin's RPC cookie once rbitcoin holds its RPC port";
      # Starts with every start of rbitcoin and stops with it, like
      # `rbitcoin-space`. Stopping removes the runtime directory and with it
      # the published cookie.
      wantedBy = [ "rbitcoin.service" ];
      bindsTo = [ "rbitcoin.service" ];
      partOf = [ "rbitcoin.service" ];
      after = [ "rbitcoin.service" ];
      serviceConfig = {
        # Waits without blocking a start job (for hours during IBD), and runs
        # for as long as the cookie is published
        Type = "exec";
        ExecStart = publishCookie;
        # root, to see which process holds the port. The group owns the
        # runtime directory.
        User = "root";
        Group = "rbitcoinrpc";
        RuntimeDirectory = "rbitcoin-rpc";
        RuntimeDirectoryMode = "0750";
        UMask = "0027";
        Restart = "on-failure";
        RestartSec = "5s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        # rbitcoin's network namespace, with netns-isolation
        NetworkNamespacePath = config.systemd.services.rbitcoin.serviceConfig.NetworkNamespacePath or null;
      };
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
