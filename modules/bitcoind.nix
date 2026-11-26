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
        default = ports.p2p;
        defaultText = literalMD (describePorts "p2p");
        description = "Port to listen for peer connections.";
      };
      onionPort = mkOption {
        type = types.nullOr types.port;
        # When the bitcoind onion service is enabled, add an onion-tagged socket
        # to distinguish local connections from Tor connections
        default = if (config.nix-bitcoin.onionServices.bitcoind.enable or false) then ports.onion else null;
        defaultText = literalMD "`null` when the bitcoind onion service is disabled, otherwise ${describePorts "onion"}.";
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
          The service fails to start when the command fails or prints nothing.
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
          default = ports.rpc;
          defaultText = literalMD (describePorts "rpc");
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

                  This value is written to the world-readable Nix store. Any local user
                  can read it and test password guesses offline. So use a long random
                  password, like the one that Bitcoin Core's `share/rpcauth/rpcauth.py`
                  generates when you don't pass a password.
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
      network = mkOption {
        type = types.enum (attrNames networkPorts);
        default = "mainnet";
        description = ''
          Bitcoin network used by the deployment's services.
          Use signet or testnet4 for a public test network.
          Use regtest for a local regression testing network.
          Evaluation fails if an enabled service is incompatible with the network.
        '';
      };
      networkDir = mkOption {
        type = types.path;
        readOnly = true;
        default = cfg.dataDir + optionalString (cfg.network != "mainnet") "/${cfg.network}";
        defaultText = literalMD "`dataDir` on mainnet, `dataDir/network` on other networks.";
        description = "The directory where Bitcoin Core stores data for the selected network.";
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
          If enabled, the bitcoind service group can read the blocks dir with the
          block files and the block index, including the files that bitcoind
          creates while it runs. To reach it, the group can search the data dir
          and the selected network's subdirectory. Where these have an ACL,
          the group's rights are added to it, and all other users and groups keep their
          effective rights. The blocks dir and the dirs between it and the data
          dir must not be symlinks, and symlinks in the blocks dir aren't followed.
          A custom `blocksdir` in `extraConfig` isn't covered.
          The `bitcoind-group-read` service sets this up before each start of bitcoind.
          It sets a default ACL, which needs POSIX ACL support on the filesystem of
          the blocks dir (on ZFS, `acltype=posixacl`). Without it, the service logs a
          warning, and the group can read only the files that exist when bitcoind starts.
          Disabling this option doesn't revoke the access that it granted, and the
          group can still read the files that bitcoind creates later. To revoke it,
          run `setfacl -P -R -n -m g::-,d:g::-` on the blocks dir. On regtest,
          signet and testnet4, also run `setfacl -P -n -m g::-` on the network
          subdirectory. Run these commands as the bitcoind user, for example
          with `runuser -u bitcoin --`. Older versions let group members put a
          symlink in the data dir. `-P` keeps setfacl from following one at the end
          of the path, and as the bitcoind user, one before it can only lead to that
          user's own files.
          Warning: This disables bitcoind's wallet support.
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
        # Read the config from the Nix store, not the copy in the data dir. Users other
        # than root can write the data dir, and the copy adds only settings that
        # bitcoin-cli doesn't use.
        # Root runs bitcoin-cli as the bitcoin user, which owns the dir of the cookie.
        default = pkgs.writers.writeBashBin "bitcoin-cli" ''
          exec ${nbLib.runAsUserIfRoot cfg.user} ${bitcoind}/bin/bitcoin-cli \
            -datadir='${cfg.dataDir}' -conf='${configFile}' "$@"
        '';
        defaultText = "(See source)";
        description = "Binary to connect with the bitcoind instance.";
      };
      tor = nbLib.tor;
    };
  };

  cfg = config.services.bitcoind;
  networkPorts = {
    mainnet  = { p2p =  8333; rpc =  8332; onion =  8334; };
    regtest  = { p2p = 18444; rpc = 18443; onion = 18445; };
    signet   = { p2p = 38333; rpc = 38332; onion = 38334; };
    testnet4 = { p2p = 48333; rpc = 48332; onion = 48334; };
  };
  ports = networkPorts.${cfg.network};
  describePorts = name: concatStringsSep ", " (mapAttrsToList
    (network: values: "${toString values.${name}} on ${network}") networkPorts);
  bitcoind = config.nix-bitcoin.pkgs.bitcoind;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  # The RPC cookie lives outside the data directory. Older versions let group
  # members write the data directory, so a group member could swap the cookie
  # for a symlink while bitcoind sets its mode by path. This directory is a
  # RuntimeDirectory with mode 0750: only the bitcoin user writes it, group
  # members read it.
  rpcCookieDir = "/run/bitcoind";

  # Lets the bitcoind group read the blocks dir, see `dataDirReadableByGroup`.
  # Bitcoin Core sets umask 077, so it creates files with mode 0600. Below a
  # dir with a default ACL, the ACL takes the place of the umask, so the group
  # can also read the files that bitcoind creates while it runs.
  groupReadScript = let
    getfacl = "${pkgs.acl}/bin/getfacl -P -n -E --";
  in ''
    # Older versions let group members rename and replace the entries of the data
    # dir at any time, so such an entry can be left from then. So enter each dir
    # only after checking it, and work only on the current dir and the names in
    # it. `setfacl -P` follows no symlink at such a name. For a path with a dir
    # part, it needs openat2(), which systemd's `RestrictSUIDSGID` blocks.
    #
    # Enters the dir $1 in the current dir. $1 must be a dir of ours when we
    # check it, and the dir we end up in must be that same dir.
    enterDir() {
      local before
      before=$(LC_ALL=C stat -c '%F %d:%i' -- "$1") && [[ $before == "directory "* ]] &&
        cd -- "./$1" && [[ -O . && $before == "directory $(stat -c '%d:%i' .)" ]]
    }
    # Gives the owning group at least the rights $1 on the entries in the getfacl
    # output on stdin, and $2 in their default ACLs. All other users and groups
    # keep their effective rights. Leaves alone the entries of other groups.
    grantGroup() {
      ${pkgs.gawk}/bin/awk -v access="$1" -v defaults="$2" -v gid="$gid" \
        -f ${./bitcoind/grant-group.awk} |
        ${pkgs.acl}/bin/setfacl -P --restore=/dev/stdin
    }
    # Prints the entries of type $1 in the current dir as `./name`. getfacl reads
    # a list of files from stdin for the name `-`.
    entries() { find . -mindepth 1 -maxdepth 1 -type "$1" -print0; }
    # Lets the group read the current dir and everything below it. Goes on after
    # a failure, so an entry of another user doesn't stop the rest.
    grantTree() {
      local failed="" dir
      ${getfacl} . | grantGroup r-x r-x || failed=1
      entries f | xargs -0r ${getfacl} | grantGroup r-- "" || failed=1
      while IFS= read -r -d "" dir; do
        (enterDir "$dir" && grantTree) || failed=1
      done < <(entries d)
      wait $! || failed=1
      [[ ! $failed ]]
    }
    setUpGroupRead() (
      set -o pipefail
      umask 077
      gid=$(id -g)
      failed=""
      cd '${cfg.dataDir}' || exit
      ${getfacl} . | grantGroup --x "" || failed=1
      ${optionalString (cfg.network != "mainnet") ''
        newNetworkDir=""
        if [[ ! -e ${cfg.network} && ! -L ${cfg.network} ]]; then
          mkdir ${cfg.network} || exit
          newNetworkDir=1
        fi
        enterDir ${cfg.network} || exit
        # Core creates `wallets` only in a network dir that it creates itself
        if [[ $newNetworkDir ]]; then mkdir wallets || exit; fi
        ${getfacl} . | grantGroup --x "" || failed=1
      ''}
      # Create the dir before bitcoind does, so the ACL covers its first files
      if [[ ! -e blocks && ! -L blocks ]]; then mkdir blocks || exit; fi
      enterDir blocks && grantTree && [[ ! $failed ]]
    )
    # A failure only costs the group read access, which is better than a node
    # without bitcoind
    if ! setUpGroupRead; then
      echo "Warning: Can't let the group read all files in ${cfg.networkDir}/blocks." \
        "It and the dirs between it and the data dir must be dirs of user ${cfg.user}" \
        "and group ${cfg.group}," \
        "not symlinks, on a filesystem with POSIX ACLs." >&2
    fi
  '';

  i2pSAM = config.services.i2pd.settings.sam;

  configFile = builtins.toFile "bitcoin.conf" ''
    # We're already logging via journald
    nodebuglogfile=1
    logtimestamps=0

    startupnotify=/run/current-system/systemd/bin/systemd-notify --ready

    ${optionalString (cfg.network != "mainnet") ''
      ${cfg.network}=1
      [${cfg.network}]
    ''}
    ${optionalString (cfg.dbCache != null) "dbcache=${toString cfg.dbCache}"}
    prune=${toString cfg.prune}
    ${optionalString cfg.txindex "txindex=1"}
    ${optionalString cfg.rest.enable "rest=1"}
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
      settings = {
        sam = {
          enabled = true;
          address = mkDefault "127.0.0.1";
          port = mkDefault 7656;
        };
        # Override NixOS's mkDefault true without preventing explicit opt-ins.
        http.enabled = mkOverride 900 false;
        httpproxy.enabled = mkOverride 900 false;
        socksproxy.enabled = mkOverride 900 false;
        ntcp2.published = mkDefault false;
        ssu2.published = mkDefault false;
      };
    };

    # Group members, like the operator, read `bitcoin.conf` here, and with
    # `dataDirReadableByGroup` the blocks dir. Nothing in the group writes here.
    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
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
      ] ++ optional cfg.dataDirReadableByGroup "bitcoind-group-read.service";
      after = wants;
      wantedBy = [ "multi-user.target" ];

      preStart = let
        extraRpcauth = concatMapStrings (name: let
          user = cfg.rpc.users.${name};
        in optionalString user.passwordHMACFromFile ''
          hmac=$(< '${secretsDir}/bitcoin-HMAC-${name}')
          extraRpcauth+="rpcauth=${user.name}:$hmac"$'\n'
        '') (builtins.attrNames cfg.rpc.users);
      in ''
        ${optionalString (cfg.getPublicAddressCmd != "")
          (nbLib.readPublicAddress "bitcoind" cfg.getPublicAddressCmd)}
        extraRpcauth=""
        ${extraRpcauth}
        cfg=$(
          cat ${configFile}
          printf '%s\n' "$extraRpcauth"
          ${optionalString (cfg.getPublicAddressCmd != "") ''
            echo "externalip=$publicAddress"
          ''}
        )
        # Always replace the file. Older versions let the operator write the data
        # dir, so the file can belong to the operator.
        install -T -m 640 <(printf '%s\n' "$cfg") '${cfg.dataDir}/bitcoin.conf'
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
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce
        // optionalAttrs zmqServerEnabled nbLib.allowNetlink;
    };

    # Runs before each start of bitcoind, which wants it. It's a unit of its
    # own, because bitcoind runs with `PrivateUsers`, which hides the users and
    # groups that an ACL names, so it can't change an ACL that names others.
    systemd.services.bitcoind-group-read = mkIf cfg.dataDirReadableByGroup {
      # Covers a mount at blocks/index, at blocks and at each dir above them
      unitConfig.RequiresMountsFor = [ (nbLib.unitPath "${cfg.networkDir}/blocks/index") ];
      # bitcoind's start limit covers this unit too
      startLimitIntervalSec = 0;
      serviceConfig = nbLib.defaultHardening // {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        PrivateUsers = false;
        PrivateNetwork = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
      script = groupReadScript;
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
