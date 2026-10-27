{ config, pkgs, lib, ... }:

with lib;
let
  options = {
    services.bitcoind = {
      enable = mkEnableOption "Bitcoin daemon";
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen for peer connections.";
      };
      port = mkOption {
        type = types.port;
        default = if !cfg.regtest then 8333 else 18444;
        defaultText = "if !cfg.regtest then 8333 else 18444";
        description = "Port to listen for peer connections.";
      };
      onionPort = mkOption {
        type = types.nullOr types.port;
        # When the bitcoind onion service is enabled, add an onion-tagged socket
        # to distinguish local connections from Tor connections
        default = if (config.nix-bitcoin.onionServices.bitcoind.enable or false) then 8334 else null;
        description = ''
          Port to listen for Tor peer connections.
          If set, inbound connections to this port are tagged as onion peers.
        '';
      };
      listen = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Listen for peer connections at `address:port`
          and `address:onionPort` (if {option}`onionPort` is set).
        '';
      };
      listenWhitelisted = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Listen for peer connections at `address:whitelistedPort`.
          Peers connected through this socket are automatically whitelisted.
        '';
      };
      whitelistedPort = mkOption {
        type = types.port;
        default = 8335;
        description = "See `listenWhitelisted`.";
      };
      getPublicAddressCmd = mkOption {
        type = types.str;
        default = "";
        description = ''
          Bash expression which outputs the public service address to announce to peers.
          If left empty, no address is announced.
        '';
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        example = ''
          par=16
          logips=1
        '';
        description = ''
          Extra lines appended to {file}`bitcoin.conf`.

          ${nbLib.extraConfigDescription}
        '';
      };
      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/bitcoind";
        description = "The data directory for bitcoind.";
      };
      rpc = {
        address = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = ''
            Address to listen for JSON-RPC connections.
          '';
        };
        port = mkOption {
          type = types.port;
          default = if !cfg.regtest then 8332 else 18443;
          defaultText = "if !cfg.regtest then 8332 else 18443";
          description = "Port to listen for JSON-RPC connections.";
        };
        threads = mkOption {
          type = types.nullOr types.ints.u16;
          default = null;
          description = "The number of threads to service RPC calls.";
        };
        allowip = mkOption {
          type = types.listOf types.str;
          default = [ "127.0.0.1" ];
          description = ''
            Allow JSON-RPC connections from specified sources.
          '';
        };
        users = mkOption {
          default = {};
          description = ''
            Allowed users for JSON-RPC connections.
          '';
          example = {
            alice = {
              passwordHMAC = "f7efda5c189b999524f151318c0c86$d5b51b3beffbc02b724e5d095828e0bc8b2456e9ac8757ae3211a5d9b16a22ae";
              rpcwhitelist = [ "sendtoaddress" "getnewaddress" ];
            };
          };
          type = with types; attrsOf (submodule ({ name, ... }: {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                example = "alice";
                description = ''
                  Username for JSON-RPC connections.
                '';
              };
              passwordHMAC = mkOption {
                type = types.str;
                example = "f7efda5c189b999524f151318c0c86$d5b51b3beffbc02b724e5d095828e0bc8b2456e9ac8757ae3211a5d9b16a22ae";
                description = ''
                  Password HMAC-SHA-256 for JSON-RPC connections. Must be a string of the
                  format `<SALT-HEX>$<HMAC-HEX>`.
                '';
              };
              passwordHMACFromFile = mkOption {
                type = lib.types.bool;
                internal = true;
                default = false;
              };
              rpcwhitelist = mkOption {
                type = types.listOf types.str;
                default = [];
                description = ''
                  List of allowed rpc calls for each user.
                  If empty list, rpcwhitelist is disabled for that user.
                '';
              };
            };
          }));
        };
      };
      regtest = mkOption {
        type = types.bool;
        default = false;
        description = "Enable regtest mode.";
      };
      network = mkOption {
        readOnly = true;
        default = if cfg.regtest then "regtest" else "mainnet";
      };
      makeNetworkName = mkOption {
        readOnly = true;
        default = mainnet: regtest: if cfg.regtest then regtest else mainnet;
      };
      proxy = mkOption {
        type = types.nullOr types.str;
        default = if cfg.tor.proxy then config.nix-bitcoin.torClientAddressWithPort else null;
        description = "Connect through SOCKS5 proxy";
      };
      i2p = mkOption {
        type = types.enum [ false true "only-outgoing" ];
        default = false;
        description = ''
          Enable peer connections via i2p.
          With `only-outgoing`, incoming i2p connections are disabled.
        '';
      };
      dataDirReadableByGroup = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If enabled, data dir content is readable by the bitcoind service group.
          Warning: This disables bitcoind's wallet support.
        '';
      };
      sysperms = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Create new files with system default permissions, instead of umask 077
          (only effective with disabled wallet functionality)
        '';
      };
      disablewallet = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Do not load the wallet and disable wallet RPC calls
        '';
      };
      dbCache = mkOption {
        type = types.nullOr (intAtLeast 4);
        default = null;
        example = 4000;
        description = "Override the default database cache size in MiB.";
      };
      prune = mkOption {
        type = types.ints.unsigned;
        default = 0;
        example = 10000;
        description = ''
          Automatically prune block files to stay under the specified target size in MiB.
          Value 0 disables pruning.
        '';
      };
      txindex = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the transaction index.";
      };
      rest = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable the REST interface.
            It is served on the RPC address and port without authentication. Every
            source allowed by `rpc.allowip` can query blocks, transactions, the UTXO
            set and the mempool, bypassing RPC users and `rpcwhitelist`.
          '';
        };
        allowNonLocal = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allow enabling the REST interface when `rpc.allowip` contains
            sources other than localhost and nix-bitcoin's network namespaces.
            These sources get unauthenticated REST access.
            For loopback, use `127.0.0.1`, `127.0.0.1/32`, `127.0.0.0/8`,
            `::1` or `::1/128` in `rpc.allowip`.
            Also accepts `rpcallowip` and `includeconf` directives in
            `extraConfig` (see `rest.allowUncheckedConfig`).
          '';
        };
        allowUncheckedConfig = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allow enabling the REST interface when `extraConfig` contains
            `rpcallowip` or `includeconf` directives. Their effective allowlist
            is not checked, so review all raw and included settings first.
            Unlike `rest.allowNonLocal`, this keeps the check of `rpc.allowip`.
          '';
        };
        localSources = mkOption {
          internal = true;
          type = types.listOf types.str;
          default = [];
          description = ''
            `rpc.allowip` entries that are considered local for `rest.allowNonLocal`,
            in addition to localhost.
          '';
        };
      };
      zmqpubrawblock = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tcp://127.0.0.1:28332";
        description = "ZMQ address for zmqpubrawblock notifications";
      };
      zmqpubrawtx = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tcp://127.0.0.1:28333";
        description = "ZMQ address for zmqpubrawtx notifications";
      };
      assumevalid = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "00000000000000000000e5abc3a74fe27dc0ead9c70ea1deb456f11c15fd7bc6";
        description = ''
          If this block is in the chain assume that it and its ancestors are
          valid and potentially skip their script verification.
        '';
      };
      addnodes = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "ecoc5q34tmbq54wl.onion" ];
        description = "Add nodes to connect to and attempt to keep the connections open";
      };
      discover = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Discover own IP addresses";
      };
      addresstype = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "bech32";
        description = "The type of addresses to use";
      };
      user = mkOption {
        type = types.str;
        default = "bitcoin";
        description = "The user as which to run bitcoind.";
      };
      group = mkOption {
        type = types.str;
        default = cfg.user;
        description = "The group as which to run bitcoind.";
      };
      cli = mkOption {
        readOnly = true;
        type = types.package;
        default = pkgs.writers.writeBashBin "bitcoin-cli" ''
          exec ${bitcoind}/bin/bitcoin-cli -datadir='${cfg.dataDir}' "$@"
        '';
        defaultText = "(See source)";
        description = "Binary to connect with the bitcoind instance.";
      };
      tor = nbLib.tor;
    };
  };

  cfg = config.services.bitcoind;
  bitcoind = config.nix-bitcoin.pkgs.bitcoind;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  # The RPC cookie lives outside the data directory. The data directory is
  # group-writable, so a group member could swap the cookie for a symlink
  # while bitcoind sets its mode by path. This directory is a RuntimeDirectory
  # with mode 0750: only the bitcoin user writes it, group members read it.
  rpcCookieDir = "/run/bitcoind";

  i2pSAM = config.services.i2pd.proto.sam;

  configFile = builtins.toFile "bitcoin.conf" ''
    # We're already logging via journald
    nodebuglogfile=1
    logtimestamps=0

    startupnotify=/run/current-system/systemd/bin/systemd-notify --ready

    ${optionalString cfg.regtest ''
      regtest=1
      [regtest]
    ''}
    ${optionalString (cfg.dbCache != null) "dbcache=${toString cfg.dbCache}"}
    prune=${toString cfg.prune}
    ${optionalString cfg.txindex "txindex=1"}
    ${optionalString cfg.rest.enable "rest=1"}
    ${optionalString (cfg.sysperms != null) "sysperms=${if cfg.sysperms then "1" else "0"}"}
    ${optionalString (cfg.disablewallet != null) "disablewallet=${if cfg.disablewallet then "1" else "0"}"}
    ${optionalString (cfg.assumevalid != null) "assumevalid=${cfg.assumevalid}"}

    # Connection options
    listen=${if (cfg.listen || cfg.listenWhitelisted) then "1" else "0"}
    ${optionalString cfg.listen
      "bind=${cfg.address}:${toString cfg.port}"}
    ${optionalString (cfg.listen && cfg.onionPort != null)
      "bind=${cfg.address}:${toString cfg.onionPort}=onion"}
    ${optionalString cfg.listenWhitelisted
      "whitebind=${cfg.address}:${toString cfg.whitelistedPort}"}
    ${optionalString (cfg.proxy != null) "proxy=${cfg.proxy}"}
    ${optionalString (cfg.i2p != false) "i2psam=${nbLib.addressWithPort i2pSAM.address i2pSAM.port}"}
    ${optionalString (cfg.i2p == "only-outgoing") "i2pacceptincoming=0"}

    ${optionalString (cfg.discover != null) "discover=${if cfg.discover then "1" else "0"}"}
    ${lib.concatMapStrings (node: "addnode=${node}\n") cfg.addnodes}

    # RPC server options
    rpcbind=${cfg.rpc.address}
    rpcport=${toString cfg.rpc.port}
    rpcconnect=${cfg.rpc.address}
    ${optionalString (cfg.rpc.threads != null) "rpcthreads=${toString cfg.rpc.threads}"}
    rpcwhitelistdefault=0
    rpccookiefile=${rpcCookieDir}/.cookie
    # Mode 0640: group members (the operator) can read the cookie
    rpccookieperms=group
    ${concatMapStrings (user: ''
        ${optionalString (!user.passwordHMACFromFile) "rpcauth=${user.name}:${user.passwordHMAC}"}
        ${optionalString (user.rpcwhitelist != [])
          "rpcwhitelist=${user.name}:${lib.strings.concatStringsSep "," user.rpcwhitelist}"}
      '') (builtins.attrValues cfg.rpc.users)
    }
    ${lib.concatMapStrings (rpcallowip: "rpcallowip=${rpcallowip}\n") cfg.rpc.allowip}

    # Wallet options
    ${optionalString (cfg.addresstype != null) "addresstype=${cfg.addresstype}"}

    # ZMQ options
    ${optionalString (cfg.zmqpubrawblock != null) "zmqpubrawblock=${cfg.zmqpubrawblock}"}
    ${optionalString (cfg.zmqpubrawtx != null) "zmqpubrawtx=${cfg.zmqpubrawtx}"}

    # Extra options
    ${cfg.extraConfig}
  '';

  zmqServerEnabled = (cfg.zmqpubrawblock != null) || (cfg.zmqpubrawtx != null);

  intAtLeast = n: types.addCheck types.int (x: x >= n) // {
    name = "intAtLeast";
    description = "integer >= ${toString n}";
  };
in {
  inherit options;

  config = mkIf cfg.enable {
    warnings = optional (cfg.extraConfig != "")
      (nbLib.extraConfigWarning "services.bitcoind.extraConfig");

    assertions = let
      localSources = [
        "127.0.0.1" "127.0.0.1/32" "127.0.0.0/8" "::1" "::1/128"
      ] ++ cfg.rest.localSources;
      nonLocalSources = subtractLists localSources cfg.rpc.allowip;
      # Raw allowlists and included files can add sources outside rpc.allowip.
      # Match section-qualified and negated keys too, but ignore comments.
      extraConfigSetsAllowlist = any (line:
        builtins.match "[[:space:]]*([^[:space:].=#]+[.])?(no)?(rpcallowip|includeconf)[[:space:]]*=.*" line != null
      ) (splitString "\n" cfg.extraConfig);
    in [
      { assertion = !cfg.rest.enable || cfg.rest.allowNonLocal || nonLocalSources == [];
        message = ''
          The bitcoind REST interface is unauthenticated and would be reachable from
          these `services.bitcoind.rpc.allowip` sources: ${concatStringsSep ", " nonLocalSources}
          Remove them, or set `services.bitcoind.rest.allowNonLocal = true` to accept this.
        '';
      }
      { assertion = !cfg.rest.enable || cfg.rest.allowNonLocal || cfg.rest.allowUncheckedConfig
                    || !extraConfigSetsAllowlist;
        message = ''
          The bitcoind REST interface is unauthenticated, and `services.bitcoind.extraConfig`
          contains `rpcallowip` or `includeconf` directives whose effective allowlist
          cannot be checked. Move RPC sources to `services.bitcoind.rpc.allowip` and
          remove the raw directives, or review all raw and included settings and set
          `services.bitcoind.rest.allowUncheckedConfig = true`.
        '';
      }
    ];

    environment.systemPackages = [ bitcoind (hiPrio cfg.cli) ];

    services.bitcoind = mkMerge [
      (mkIf cfg.dataDirReadableByGroup {
        disablewallet = true;
        sysperms = true;
      })
      {
        rpc.users.privileged = {
          passwordHMACFromFile = true;
        };
        rpc.users.public = {
          passwordHMACFromFile = true;
          rpcwhitelist = import ./bitcoind-rpc-public-whitelist.nix;
        };
      }
    ];

    services.i2pd = mkIf (cfg.i2p != false) {
      enable = true;
      proto.sam.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.bitcoind = rec {
      wants = [
        "network-online.target"
        # Use `wants` instead of `requires` for `nix-bitcoin-secrets.target`
        # so that bitcoind and all dependent services are not restarted when
        # the secrets target restarts.
        # The secrets target always restarts when deploying with one of the methods
        # in ./deployment.
        #
        # TODO-EXTERNAL: Instead of `wants`, use a future systemd dependency type
        # that propagates initial start failures but no restarts
        "nix-bitcoin-secrets.target"
      ];
      after = wants;
      wantedBy = [ "multi-user.target" ];

      preStart = let
        extraRpcauth = concatMapStrings (name: let
          user = cfg.rpc.users.${name};
        in optionalString user.passwordHMACFromFile ''
            echo "rpcauth=${user.name}:$(cat ${secretsDir}/bitcoin-HMAC-${name})"
          ''
        ) (builtins.attrNames cfg.rpc.users);
      in ''
        ${optionalString cfg.dataDirReadableByGroup ''
          if [[ -e '${cfg.dataDir}/blocks' ]]; then
            chmod -R g+rX '${cfg.dataDir}/blocks'
          fi
        ''}

        cfg=$(
          cat ${configFile}
          ${extraRpcauth}
          echo
          ${optionalString (cfg.getPublicAddressCmd != "") ''
            echo "externalip=$(${cfg.getPublicAddressCmd})"
          ''}
        )
        # Always replace the file. The data dir is writable by the operator, which
        # could plant an operator-owned file with identical content to skip the update.
        install -T -o '${cfg.user}' -g '${cfg.group}' -m 640 <(echo "$cfg") '${cfg.dataDir}/bitcoin.conf'
      '';

      serviceConfig = nbLib.defaultHardening // {
        Type = "notify";
        NotifyAccess = "all";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = baseNameOf rpcCookieDir;
        RuntimeDirectoryMode = "0750";
        TimeoutStartSec = "30min";
        TimeoutStopSec = "30min";
        ExecStart = "${bitcoind}/bin/bitcoind -datadir='${cfg.dataDir}'";
        Restart = "on-failure";
        UMask = mkIf cfg.dataDirReadableByGroup "0027";
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce
        // optionalAttrs zmqServerEnabled nbLib.allowNetlink;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};
    users.groups.bitcoinrpc-public = {};

    nix-bitcoin.operator.groups = [ cfg.group ];

    nix-bitcoin.secrets = {
      bitcoin-rpcpassword-privileged.user = cfg.user;
      bitcoin-rpcpassword-public = {
        user = cfg.user;
        group = "bitcoinrpc-public";
      };

      bitcoin-HMAC-privileged.user = cfg.user;
      bitcoin-HMAC-public.user = cfg.user;
    };
    nix-bitcoin.generateSecretsCmds.bitcoind = ''
      makeBitcoinRPCPassword privileged
      makeBitcoinRPCPassword public
    '';
  };
}
