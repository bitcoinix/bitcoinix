# Integration tests, can be run without internet access.

lib: nixBitcoinModule:
let
  # Included in all scenarios
  baseConfig = { config, pkgs, ... }: with lib; let
    cfg = config.services;
    nbLib = config.nix-bitcoin.lib;
    inherit (nbLib.test) mkIfTest;
  in {
    imports = [
      ./lib/test-lib.nix
      nixBitcoinModule
      {
        # Features required by the Python test suite
        nix-bitcoin.secretsDir = "/secrets";
        nix-bitcoin.generateSecrets = true;
        nix-bitcoin.operator.enable = true;
        environment.systemPackages = with pkgs; [ jq ];
        # A fixed value, so that a new commit doesn't change every test derivation
        nix-bitcoin.revision = "0123456789abcdef0123456789abcdef01234567";
      }
    ];

    options.test.features = {
      clightningPlugins = mkEnableOption "all clightning plugins";
    };

    config = mkMerge [{
      environment.systemPackages = mkMerge (with pkgs; [
        # Needed to test macaroon creation
        (mkIfTest "btcpayserver" [ openssl xxd ])
        # Needed to test certificate creation
        (mkIfTest "lnd" [ openssl ])
        # Needed to authenticate with charge-lnd's macaroon
        (mkIfTest "charge-lnd" [ curl xxd ])
        # Compare the certificate in a connection URL with the live TLS certificate
        (mkIfTest "lnconnect-clnrest-cert" [ openssl ])
        # Creates the cert of a fake RTL backend
        (mkIfTest "rtl-backend-certs" [ openssl ])
        # Calls lnd, clnrest and RTL's API with RTL's credentials
        (mkIfTest "rtl-permissions" [ curl xxd ])
        # Needed to trace the commands run by secret generation
        (mkIfTest "secrets-no-argv" [ strace ])
        # Talks to the Electrum relay
        (mkIfTest "unbeholden-wallet" [ websocat ])
        # Check that initialization guards reject ACL write access.
        (mkIfTest "cdk-mintd" [ acl ])
        (mkIfTest "orchard" [ grpcurl acl ])
      ]);

      tests.bitcoind = cfg.bitcoind.enable;
      test.data.bitcoinNetwork = cfg.bitcoind.network;
      # lnd requires bitcoind and stops with it, also when test `lnd` is off
      test.data.restart-bitcoind.lnd = cfg.lnd.enable;
      # These stop and start with the bridge, also when their tests are off
      test.data.netns-bridge-restart = {
        bitcoind = cfg.bitcoind.enable;
        lnd = cfg.lnd.enable;
        charge-lnd = cfg.charge-lnd.enable;
        restrict-forwarding = config.nix-bitcoin.netns-isolation.restrictForwarding;
      };

      tests.i2pd = cfg.bitcoind.enable && cfg.bitcoind.i2p != false;
      # Scenarios that set `tests = mkForce { ... }` have no `tests.i2pd`
      test.data.i2pd = optionalAttrs (config.tests.i2pd or false) {
        inherit (cfg.i2pd.settings.sam) address port;
        netns = config.nix-bitcoin.netns-isolation.enable;
      };

      test.data.bitcoind-group-read = {
        inherit (cfg.bitcoind) dataDir network networkDir;
      };

      tests.secrets-no-argv = cfg.bitcoind.enable;
      test.data.secrets-no-argv.generator = "${config.nix-bitcoin.generateSecretsScript}";

      tests.rpc-whitelist = cfg.bitcoind.enable;
      # Which services are enabled decides which RPC users exist and what they may call
      test.data.rpc-whitelist = {
        btcpayserver = cfg.btcpayserver.enable;
        clightning = cfg.clightning.enable;
        clightning-bcli = cfg.clightning.enable && cfg.clightning.useBcliPlugin;
        mempool = cfg.mempool.enable;
      };

      tests.bitcoind-rest = cfg.bitcoind.enable;
      test.data.bitcoind-rest = {
        inherit (cfg.bitcoind.rest) enable;
        rpcPort = cfg.bitcoind.rpc.port;
        chain = nbLib.networkName { mainnet = "main"; };
      };

      services.bitcoind = {
        enable = true;
        extraConfig = mkIf config.test.noConnections "connect=0";
      };

      tests.clightning = cfg.clightning.enable;
      test.data.clightning = { inherit (cfg.clightning) dataDir networkDir user group; };
      test.data.clightning-replication = with cfg.clightning.replication; optionalAttrs enable {
        inherit (cfg.clightning) wallet;
        encryptedLocalDir = if encrypt then local.directory else null;
      };
      tests.clnrest-admin-rune = with cfg.clightning.plugins.clnrest; enable && createAdminRune;
      test.data.clnrest-admin-rune = {
        file = "${cfg.clightning.networkDir}/admin-rune";
        inherit (cfg.clightning) user;
        inherit (cfg.clightning.plugins.clnrest) port;
        # RTL's copy of the rune
        rtlFile = if cfg.rtl.enable && cfg.rtl.nodes.clightning.enable
          then "${cfg.rtl.dataDir}/clightning-admin-rune"
          else null;
      };
      tests.trustedcoin = cfg.clightning.plugins.trustedcoin.enable;

      # TODO-EXTERNAL:
      # When WAN is disabled, DNS bootstrapping slows down service startup by ~15 s.
      services.clightning.extraConfig = ''
        ${optionalString config.test.noConnections "disable-dns"}
      '';
      test.data.clightning-plugins = let
        plugins = config.services.clightning.plugins;
        removed = [
          # Only defined via `obsolete-options.nix`
          "commando"
          "helpme"
          "prometheus"
          "summary"
        ];
        available = subtractLists removed (builtins.attrNames plugins);
        enabled = builtins.filter (plugin: plugins.${plugin}.enable) available;
        nbPkgs = config.nix-bitcoin.pkgs;
        pluginPkgs = nbPkgs.clightning-plugins // {
          clboss.path = "${plugins.clboss.package}/bin/clboss";
          clnrest = plugins.clnrest.package;
          trustedcoin.path = "${plugins.trustedcoin.package}/bin/trustedcoin";
        };
      in map (plugin: pluginPkgs.${plugin}.path) enabled;

      # Services that use `nix-bitcoin.lib.defaultHardening`, with their `ReadOnlyPaths`
      tests.hardening-ro-paths = true;
      test.data.hardening-ro-paths = let
        # This syscall blocklist entry is specific to `defaultHardening`
        marker = builtins.elemAt config.nix-bitcoin.lib.defaultHardening.SystemCallFilter 1;
        usesDefaultHardening = service:
          builtins.elem marker (toList (service.serviceConfig.SystemCallFilter or []));
      in mapAttrs (_: service: toList (service.serviceConfig.ReadOnlyPaths or []))
        (filterAttrs (_: usesDefaultHardening) config.systemd.services);

      # Services restricted to local addresses (`nix-bitcoin.lib.allowLocalIPAddresses`)
      tests.tor-enforce = true;
      test.data.tor-enforce = let
        # Select units by either part of the restriction, so that a unit that
        # overrides its allow list or its masks fails the test instead of dropping out.
        # A unit without a network of its own, like rtl-proxy, has no IP filter to check.
        isRestricted = service: let serviceConfig = service.serviceConfig; in
          !(serviceConfig.PrivateNetwork or false)
          && (elem "127.0.0.1/32" (toList (serviceConfig.IPAddressAllow or []))
              || elem "/run/nscd" (toList (serviceConfig.InaccessiblePaths or [])));
        netns = config.nix-bitcoin.netns-isolation;
      in {
        selected = attrNames (filterAttrs (_: isRestricted) config.systemd.services);
        # The units that must be restricted, independent of how they're selected
        expected = [ "nb-tor-enforce-custom" ]
          ++ optional cfg.charge-lnd.enable "charge-lnd"
          ++ optional cfg.unbeholden-wallet.enable "unbeholden-wallet"
          ++ optional (cfg.btcpayserver.enable && cfg.nbxplorer.tor.enforce) "nbxplorer"
          ++ filter (service: cfg.${service}.enable && cfg.${service}.tor.enforce) [
            "bitcoind" "btcpayserver" "clightning" "electrs" "fulcrum" "lnd" "mempool" "rtl" "unbeholden-lnurl" "cdk-mintd" "orchard"
          ];
        # The complete allow list of each restricted unit
        allow = [ "127.0.0.1/32" "::1/128" ]
          ++ optional netns.enable "169.254.${toString netns.addressblock}.0/24";
        extraAllow.unbeholden-wallet = cfg.unbeholden-wallet.allowedClients;
      };
      # A custom unit with the restriction, which must start on every node,
      # also when no service enforces Tor
      systemd.services.nb-tor-enforce-custom = mkIfTest "tor-enforce" {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = config.nix-bitcoin.lib.allowLocalIPAddresses // {
          IPAddressDeny = "any";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };

      tests.rtl = cfg.rtl.enable;
      tests.rtl-credentials = cfg.rtl.enable;
      tests.rtl-backend-certs = cfg.rtl.enable;
      tests.rtl-permissions = cfg.rtl.enable;
      tests.rtl-stops-with-backend = cfg.rtl.enable;
      test.data.rtl-credentials = optionalAttrs cfg.rtl.enable {
        inherit (cfg.rtl) dataDir user group address port;
        lnd = if cfg.rtl.nodes.lnd.enable then { inherit (cfg.lnd) networkDir user restPort; } else null;
        clightning = if cfg.rtl.nodes.clightning.enable then {
          inherit (cfg.clightning) networkDir user;
          inherit (cfg.clightning.plugins.clnrest) port createAdminRune;
        } else null;
      };
      # Scenarios that set `tests = mkForce { ... }` have no `tests.rtl`
      test.data.rtl = optionalAttrs (config.tests.rtl or false) {
        inherit (cfg.rtl) address port;
        proxy = !config.nix-bitcoin.netns-isolation.enable;
        # Where RTL's onion service forwards to
        onionTarget = let
          mapping = head (config.services.tor.relay.onionServices.rtl.map or [ null ]);
        in if mapping == null then null else { inherit (mapping.target) addr port; };
      };
      # A short, fixed restart delay. Then the crash loop in `test_rtl` is fast, and
      # its restarts would hit systemd's default start limit if the proxy had one.
      systemd.services.rtl-proxy = mkIf (cfg.rtl.enable && !config.nix-bitcoin.netns-isolation.enable) {
        serviceConfig = { RestartSec = mkForce "100ms"; RestartSteps = mkForce 0; };
      };
      services.rtl = {
        nodes = {
          lnd = {
            enable = mkDefault true;
            extraConfig.Settings.userPersona = "MERCHANT";
          };
          clightning.enable = mkDefault true;
        };
        extraCurrency = mkDefault "CHF";
      };
      # Use a simple, non-random password for manual web interface tests
      nix-bitcoin.generateSecretsCmds.rtl = mkIf cfg.rtl.enable (mkForce ''
        echo a > rtl-password
      '');

      tests.mempool = cfg.mempool.enable;
      services.mempool = {
        electrumServer = "fulcrum";
        settings.MEMPOOL.POOLS_JSON_URL = mkIf config.test.noConnections "disable-pool-fetching";
      };

      tests.orchard = cfg.orchard.enable;
      test.data.orchard = optionalAttrs cfg.orchard.enable {
        inherit (cfg.orchard) port user group dataDir setupKeyFile mintRpcPort;
        rpcAddress = cfg.cdk-mintd.settings.mint_management_rpc.address;
        rpcTlsDir = "/run/orchard-rpc-tls";
        proto = "${cfg.orchard.package}/lib/cashu-orchard/proto/cdk/cdk-mint-rpc.proto";
        inherit (cfg.cdk-mintd) seedFile;
        mintBackend = cfg.cdk-mintd.backend;
        mintDataDir = cfg.cdk-mintd.dataDir;
        mintPort = cfg.cdk-mintd.port;
        clnNetworkDir = cfg.clightning.networkDir;
      };

      tests.cdk-mintd = cfg.cdk-mintd.enable;
      test.data.cdk-mintd = optionalAttrs cfg.cdk-mintd.enable {
        inherit (cfg.cdk-mintd) port backend dataDir user group seedFile;
        mnemonicFile = cfg.cdk-mintd.onchain.mnemonicFile;
        onchain = cfg.cdk-mintd.onchain.enable;
        generatedSeed = config.nix-bitcoin.generateSecrets && config.nix-bitcoin.setupSecrets
          && (config.nix-bitcoin.secrets ? cdk-mintd-seed);
        cli = "${cfg.cdk-mintd.package}/bin/cdk-mintd --work-dir ${cfg.cdk-mintd.dataDir}";
        walletCli = "${cfg.cdk-mintd.package}/bin/cdk-cli";
        peerPort = cfg.clightning.port;
        lndCli = lib.optionalString (cfg.cdk-mintd.backend == "lnd")
          "${cfg.lnd.package}/bin/lncli --rpcserver ${lib.escapeShellArg cfg.lnd.rpcEndpoint} --tlscertpath ${lib.escapeShellArg cfg.lnd.certPath} --macaroonpath /run/cdk-mintd/lnd.macaroon";
      };

      tests.unbeholden-lnurl = cfg.unbeholden-lnurl.enable;
      test.data.unbeholden-lnurl = {
        inherit (cfg.unbeholden-lnurl) port backend dataDir;
        clnDataDir = cfg.clightning.dataDir;
      };

      tests.unbeholden-wallet = cfg.unbeholden-wallet.enable;
      test.data.unbeholden-wallet = {
        inherit (cfg.unbeholden-wallet) electrumServer allowedHosts;
      };

      tests.lnd = cfg.lnd.enable;
      tests.lnd-wallet-init = cfg.lnd.enable;
      test.data.lnd-wallet-init = if cfg.lnd.enable then {
        inherit (cfg.lnd) dataDir networkDir user group;
        preStart = toString config.systemd.services.lnd.serviceConfig.ExecStartPre;
      } else null;
      tests.lnd-macaroons = cfg.lnd.enable && cfg.lnd.macaroons != {};
      # Also without custom macaroons, as lnd still deletes stale ones then
      tests.lnd-macaroon-revocation = cfg.lnd.enable;
      test.data.lnd-macaroons = {
        inherit (cfg.lnd) dataDir networkDir user;
        users = mapAttrs (_: macaroon: macaroon.user) cfg.lnd.macaroons;
        rootKeyIds = mapAttrs (_: macaroon: macaroon.rootKeyId) cfg.lnd.macaroons;
      };
      services.lnd = {
        port = 9736;
        certificate = {
          extraIPs = [ "10.0.0.1" "20.0.0.1" ];
          extraDomains = [ "example.com" ];
        };
      };

      nix-bitcoin.onionServices.lnd.public = true;
      test.data.lnd-public-onion = let
        onion = config.nix-bitcoin.onionServices.lnd;
        # The mapping to lnd's peer port, picked as in modules/lnd.nix
        mapping = findFirst (mapping: (mapping.target.port or mapping.port) == cfg.lnd.port) null
          (config.services.tor.relay.onionServices.lnd.map or []);
      in if cfg.lnd.enable && onion.enable && onion.public && mapping != null then {
        addressFile = "${config.nix-bitcoin.onionAddresses.dataDir}/services/lnd";
        inherit (mapping) port;
        inherit (cfg.lnd) user;
        conf = "${cfg.lnd.dataDir}/lnd.conf";
        preStart = toString config.systemd.services.lnd.serviceConfig.ExecStartPre;
      } else null;

      tests.onion-addresses = config.nix-bitcoin.onionAddresses.access != {};
      test.data.onion-addresses = let
        inherit (config.nix-bitcoin) onionAddresses;
      in {
        inherit (onionAddresses) access dataDir;
        serviceUsers = genAttrs onionAddresses.services (service:
          config.systemd.services.${service}.serviceConfig.User
        );
      };

      tests.lndconnect-onion-lnd = with cfg.lnd.lndconnect; enable && onion;
      tests.lnconnect-onion-clnrest = with cfg.clightning.plugins.clnrest.lnconnect; enable && onion;
      tests.lnconnect-clnrest-cert = with cfg.clightning.plugins.clnrest;
        enable && lnconnect.enable && !lnconnect.onion;
      tests.lnconnect-clnrest-files = with cfg.clightning.plugins.clnrest; enable && lnconnect.enable;
      test.data.lnconnect-clnrest-files.onion = cfg.clightning.plugins.clnrest.lnconnect.onion;

      # lndconnect without onion must leave the REST servers on localhost.
      # With netns-isolation, the addresses are set by netns-isolation.
      tests.lndconnect-local-bind =
        !config.nix-bitcoin.netns-isolation.enable
        && config.test.data.lndconnect-local-bind != [];
      test.data.lndconnect-local-bind =
        optional (with cfg.lnd; enable && lndconnect.enable && !lndconnect.onion) {
          unit = "lnd";
          port = cfg.lnd.restPort;
        }
        ++ optional (with cfg.clightning.plugins.clnrest; enable && lnconnect.enable && !lnconnect.onion) {
          unit = "clightning";
          port = cfg.clightning.plugins.clnrest.port;
        };

      # Config files in dirs writable by the service user.
      # `planter` is the user that plants the replacement file.
      tests.config-replace = config.test.data.config-replace != [];
      test.data.config-replace =
        # Only the service user can write the bitcoind and clightning data dirs.
        # Older versions let group members write them, so a symlink can be left
        # from then.
        optional cfg.bitcoind.enable {
          unit = "bitcoind";
          file = "${cfg.bitcoind.dataDir}/bitcoin.conf";
          mode = "640";
          inherit (cfg.bitcoind) user;
          planter = cfg.bitcoind.user;
        }
        ++ optional cfg.clightning.enable {
          unit = "clightning";
          file = "${cfg.clightning.dataDir}/config";
          mode = "640";
          inherit (cfg.clightning) user;
          planter = cfg.clightning.user;
        }
        # The operator can run as lnd, so lnd plants the file itself
        ++ optional cfg.lnd.enable {
          unit = "lnd";
          file = "${cfg.lnd.dataDir}/lnd.conf";
          mode = "600";
          inherit (cfg.lnd) user;
          planter = cfg.lnd.user;
        }
        ++ optional cfg.nbxplorer.enable {
          unit = "nbxplorer";
          file = "${cfg.nbxplorer.dataDir}/settings.config";
          mode = "600";
          inherit (cfg.nbxplorer) user;
          planter = cfg.nbxplorer.user;
        }
        ++ optional cfg.electrs.enable {
          unit = "electrs";
          file = "${cfg.electrs.dataDir}/electrs.toml";
          mode = "600";
          inherit (cfg.electrs) user;
          planter = cfg.electrs.user;
        }
        ++ optional cfg.mempool.enable {
          unit = "mempool";
          file = config.systemd.services.mempool.environment.MEMPOOL_CONFIG_FILE;
          mode = "600";
          inherit (cfg.mempool) user;
          planter = cfg.mempool.user;
        };

      tests.charge-lnd = cfg.charge-lnd.enable;

      tests.electrs = cfg.electrs.enable;

      services.fulcrum.port = 50002;
      tests.fulcrum = cfg.fulcrum.enable;

      tests.btcpayserver = cfg.btcpayserver.enable;
      services.btcpayserver.lightningBackend = mkDefault "lnd";
      test.data.btcpayserver = { inherit (cfg.btcpayserver) lightningBackend; };

      tests.nodeinfo = config.nix-bitcoin.nodeinfo.enable;
      # The version of the package each enabled service runs
      test.data.nodeinfo-versions = mapAttrs (_: pkg: pkg.version)
        (filterAttrs (name: _: cfg.${name}.enable) {
          inherit (config.nix-bitcoin.pkgs) bitcoind electrs fulcrum rtl;
          clightning = cfg.clightning.package;
          lnd = cfg.lnd.package;
          cdk-mintd = cfg.cdk-mintd.package;
          orchard = cfg.orchard.package;
          btcpayserver = cfg.btcpayserver.package;
          mempool = cfg.mempool.package;
        });

      tests.backups = cfg.backups.enable;
      test.data.backups = {
        inherit (cfg.backups) with-bulk-data;
        bitcoindDir = cfg.bitcoind.dataDir;
      };

      tests.setup-secrets = config.nix-bitcoin.setupSecrets;
      test.data.setup-secrets-declared = let
        names = builtins.attrNames config.nix-bitcoin.secrets;
      in if names == [] then null else builtins.head names;

      # To test that unused secrets are made inaccessible by 'setup-secrets'
      systemd.services.setup-secrets.preStart = mkIfTest "security" ''
        install -D -o nobody -g nogroup -m777 <(:) /secrets/dummy
      '';

      # Avoid timeout failures on slow CI nodes
      systemd.services.postgresql.serviceConfig.TimeoutStartSec = "5min";
    }
    (mkIf config.services.clightning.plugins.clboss.enable {
      # Torified 'dig' subprocesses of clboss don't respond to SIGTERM and keep
      # running for a long time when WAN is disabled, which prevents clightning units
      # from stopping quickly.
      # Set TimeoutStopSec for faster stopping.
      systemd.services.clightning.serviceConfig.TimeoutStopSec = "500ms";
    })
    (mkIf config.test.features.clightningPlugins {
      services.clightning.plugins = {
        clboss.enable = true;
        currencyrate.enable = true;
        feeadjuster.enable = true;
        monitor.enable = true;
        rebalance.enable = true;
        zmq = let tcpEndpoint = "tcp://127.0.0.1:5501"; in {
          enable = true;
          channel-opened = tcpEndpoint;
          connect = tcpEndpoint;
          disconnect = tcpEndpoint;
          invoice-payment = tcpEndpoint;
          warning = tcpEndpoint;
          forward-event = tcpEndpoint;
          sendpay-success = tcpEndpoint;
          sendpay-failure = tcpEndpoint;
        };
      };
    })
    ];
  };

  scenarios = with lib; genAttrs [ "signet" "testnet4" ] (network: {
    services.bitcoind = { inherit network; listen = true; };
    services.btcpayserver = { enable = true; lightningBackend = "clightning"; };
    services.clightning.plugins = {
      clboss.enable = network == "signet";
      trustedcoin.enable = network == "signet";
    };
    services.unbeholden-wallet.enable = true; # electrs
    services.mempool.enable = true; # Fulcrum, selected by baseConfig
  }) // {
    # Included in all scenarios by ./lib/make-test.nix
    base = baseConfig;

    default = scenarios.secureNode;

    # Supply secrets before setup-secrets, which must not generate them itself.
    setup-secrets = { config, ... }: {
      nix-bitcoin = {
        generateSecrets = mkForce false;
        setupSecrets = true;
        secrets = genAttrs [ "first" "second" "empty" ] (name: {
          user = "nobody";
          group = "nogroup";
          allowEmpty = name == "empty";
        });
      };
      systemd.services.supply-test-secrets = {
        requiredBy = [ "setup-secrets.service" ];
        before = [ "setup-secrets.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Provision the fixtures once, so restarts cannot repair missing files.
        script = ''
          install -d -m 0700 /secrets
          cd /secrets
          ${config.nix-bitcoin.generateSecretsScript}
          printf first-secret > first
          printf second-secret > second
          touch empty
        '';
      };
      tests.setup-secrets-supplied = true;
    };

    # All available basic services and tests
    full = {
      tests.security = true;

      services.clightning.enable = true;
      services.clightning.replication = {
        enable = true;
        encrypt = true;
        local.directory = "/var/backup/clightning";
      };
      services.clightning.plugins.clnrest = {
        enable = true;
        lnconnect = { enable = true; onion = true; };
      };
      test.features.clightningPlugins = true;
      services.rtl.enable = true;
      services.lnd.enable = true;
      services.lnd.lndconnect = { enable = true; onion = true; };
      services.charge-lnd.enable = true;
      services.mempool.enable = true;
      services.unbeholden-wallet.enable = true;
      services.unbeholden-wallet.electrumServer = "fulcrum";
      services.electrs.enable = true;
      services.fulcrum.enable = true;
      services.btcpayserver.enable = true;
      services.backups.enable = true;

      nix-bitcoin.nodeinfo.enable = true;

      services.hardware-wallets = {
        trezor = true;
        ledger = true;
      };
    };

    secureNode = {
      imports = [
        scenarios.full
        ../modules/presets/secure-node.nix
      ];
      tests.secure-node = true;
      tests.restart-bitcoind = true;

      nix-bitcoin.onionServices.mempool-frontend.enable = true;

      # Stop electrs from spamming the test log with 'WARN - wait until IBD is over' messages
      tests.stop-electrs = true;
    };

    netns = {
      imports = with scenarios; [ netnsBase secureNode ];
      # This test is rather slow and unaffected by netns settings
      tests.backups = mkForce false;
    };

    # All regtest-enabled services
    regtest = {
      imports = [ scenarios.regtestBase ];
      services.bitcoind.rest.enable = true;
      services.clightning.enable = true;
      services.clightning.plugins.clnrest = {
        enable = true;
        lnconnect.enable = true;
      };
      test.features.clightningPlugins = true;
      services.rtl.enable = true;
      services.mempool.enable = true;
      services.unbeholden-wallet.enable = true;
      services.unbeholden-wallet.electrumServer = "fulcrum";
      services.lnd.enable = true;
      services.lnd.lndconnect.enable = true;
      services.charge-lnd.enable = true;
      services.electrs.enable = true;
      services.fulcrum.enable = true;
      services.btcpayserver.enable = true;
    };

    # netns and regtest, without secure-node.nix
    netnsRegtest = let
      # Unlike `regtest`, give clnrest's certs a dir of their own.
      # A relative dir starts at the network dir.
      clnrestCerts = "rest-certs";
    in {
      imports = with scenarios; [ netnsBase regtest ];
      services.clightning.extraConfig = "clnrest-certs=${clnrestCerts}";
      test.data.clnrest-certs = clnrestCerts;
      tests.netns-bridge-restart = true;
    };

    # lnd without the `walletrpc` build tag lacks the RPCs of `walletrpc.WalletKit`.
    # RTL still starts, and its macaroon gets only its other permissions.
    lndWithoutWalletrpc = { config, ... }: {
      imports = [ scenarios.regtestBase ];
      services.lnd.package = let inherit (config.nix-bitcoin.pkgs) lnd; in
        lnd.override { tags = remove "walletrpc" lnd.tags; };
      services.rtl = { enable = true; nodes.lnd.enable = true; nodes.clightning.enable = false; };
      test.data.lnd-missing-services = [ "walletrpc.WalletKit" ];
    };

    hardened = {
      imports = [
        scenarios.secureNode
        ../modules/presets/hardened-extended.nix
      ];
      # Run test `tor-enforce` with glibc's nscd, which keeps a pid file
      services.nscd.enableNsncd = false;
    };

    netnsBase = { config, pkgs, ... }: {
      nix-bitcoin.netns-isolation.enable = true;
      test.data.netns = config.nix-bitcoin.netns-isolation.netns;
      test.data.netns-bridge-ip = config.nix-bitcoin.netns-isolation.bridgeIp;
      tests.netns-isolation = true;
      tests.netns-forwarding = true;
      environment.systemPackages = [ pkgs.fping ];
      # The netns-isolation test checks that the service namespaces inherit this
      boot.kernel.sysctl."net.mptcp.enabled" = "0";
    };

    regtestBase = { config, pkgs, ... }: {
      tests.regtest = true;
      # On regtest, electrs is live at this point and the Lightning daemons
      # are synced, so the restart test covers fully running dependents.
      tests.restart-bitcoind = true;
      tests.lnd-restart-on-clean-exit = config.services.lnd.enable;
      test.data.num_blocks = 100;

      services.bitcoind.network = "regtest";
      systemd.services.bitcoind.postStart = mkAfter ''
        cli=${config.services.bitcoind.cli}/bin/bitcoin-cli
        if ! $cli listwallets | ${pkgs.jq}/bin/jq -e 'index("test")'; then
          "$cli" -named createwallet  wallet_name=test load_on_startup=true
          address=$($cli -rpcwallet=test getnewaddress)
          "$cli" generatetoaddress ${toString config.test.data.num_blocks} "$address"
        fi
      '';
    };

    # The WireGuard preset with iptables-legacy next to nftables, as docs/service/zeus.md
    # describes. The default kernel lacks legacy xtables, so use one that has them.
    wireguardIptablesLegacy = { config, pkgs, ... }: {
      imports = [ ../modules/presets/wireguard.nix ];
      boot.kernelPackages = pkgs.linuxPackages_6_12;
      services.lnd = { enable = true; lndconnect.enable = true; };
      networking.nftables = {
        enable = true;
        # Setting `ruleset` turns on `flushRuleset`
        ruleset = "table inet extra { }";
      };
      networking.firewall = {
        backend = "iptables";
        package = pkgs.iptables-legacy;
      };
      tests = mkForce { wireguard-iptables-legacy = true; };
      test.extraTestScript = let
        iptables = "${pkgs.iptables-legacy}/bin/iptables -w";
      in ''
        @test("wireguard-iptables-legacy")
        def test_wireguard_iptables_legacy():
            def assert_rules():
                assert_running("firewall.service")
                rules = succeed("${iptables} -S nixos-fw").splitlines()
                rest_port = "--dport ${toString config.services.lnd.restPort}"
                assert any("-i wg-nb" in r and rest_port in r for r in rules), "\n".join(rules)
                assert "-j REJECT" in rules[1], f"restrictPeer rule is not first: {rules[1]}"
                machine.fail("nft list ruleset | grep -q nixos-fw")

            assert_running("nftables.service")
            assert_rules()
            for action in ["reload", "restart"]:
                # The flush deletes this table, so its absence shows that the flush ran
                succeed("nft add table inet probe")
                succeed(f"systemctl {action} nftables.service")
                machine.fail("nft list table inet probe")
                succeed("nft list table inet extra")
                assert_rules()
      '';
    };

    # An operator account without the operator role, set up as docs/upgrading/0.1.6.md
    # describes: explicit clnrest onion access and the clightning group
    lnconnectNoOperatorRole = {
      nix-bitcoin.operator.enable = mkForce false;
      users.users.operator = {
        isNormalUser = true;
        extraGroups = [ "clightning" ];
      };
      nix-bitcoin.onionAddresses.access.operator = [ "clnrest" ];
      services.clightning = {
        enable = true;
        plugins.clnrest = {
          enable = true;
          lnconnect = { enable = true; onion = true; };
        };
      };
      tests = mkForce {
        clightning = true;
        lnconnect-onion-clnrest = true;
      };
    };

    # The service-name shortcut needs the same regtest invoice/payment fixture.
    cdk-mintd = scenarios.cdk-mintd-lnd;

    cdk-mintd-lnd = { config, ... }: {
      imports = [ scenarios.regtestBase ];
      nix-bitcoin.nodeinfo.enable = true;
      # Exercise the shared gRPC endpoint against the actual TLS certificate.
      # Netns isolation overrides this with LND's namespace address.
      services.lnd.rpcAddress = mkDefault "::";
      # A second Lightning node provides real channel liquidity and receives
      # melts. The CLN-backed scenarios use this node as their mint backend.
      services.clightning.enable = true;
      tests.cdk-mintd-lightning = config.services.cdk-mintd.backend == "lnd";
      nix-bitcoin.netns-isolation.services.clightning.connections =
        lib.optional (config.services.cdk-mintd.backend == "lnd") "lnd";
      services.cdk-mintd = {
        enable = true;
        settings.mint_info.name = "Bitcoinix test mint";
      };
    };

    orchard = { config, pkgs, ... }: let
      socks = config.services.tor.client.socksListenAddress;
    in {
      imports = [ scenarios.regtestBase ];
      nix-bitcoin.nodeinfo.enable = true;
      services.orchard.enable = true;
      services.orchard.tor = { proxy = true; enforce = true; };
      services.cdk-mintd.settings.mint_info.name = "Bitcoinix test mint";
      # Exercise Tor routing without internet access, including proxy-side DNS.
      test.data.orchard.socksAddress = socks.addr;
      test.data.orchard.socksPort = socks.port;
      systemd.services.orchard-test-socks = {
        wantedBy = [ "multi-user.target" ];
        after = optional config.nix-bitcoin.netns-isolation.enable "nb-netns-bridge.service";
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${./lib/orchard-socks.py} ${socks.addr} ${toString socks.port}";
      };
      # Keep this scenario focused on Orchard; the CDK scenarios cover payments
      # and recovery. Orchard tests exercise both RPC and database access.
      tests.cdk-mintd = mkForce false;
    };

    orchard-netns = {
      imports = with scenarios; [ orchard netnsBase ];
      services.cdk-mintd.backend = "clightning";
    };

    cdk-mintd-cln = {
      imports = [ scenarios.cdk-mintd-lnd ];
      services.cdk-mintd.backend = "clightning";
    };

    cdk-mintd-lnd-netns = {
      imports = with scenarios; [ cdk-mintd-lnd netnsBase ];
    };

    cdk-mintd-cln-netns = {
      imports = with scenarios; [ cdk-mintd-cln netnsBase ];
    };

    cdk-mintd-onchain = { config, pkgs, extendModules, ... }: {
      imports = with scenarios; [ cdk-mintd-cln netnsBase ];
      # These tests depend on the supplied secrets, recovery variants and
      # pause wrappers below, rather than just an enabled mint or backup service.
      tests.cdk-mintd-onchain = true;
      tests.cdk-mintd-backup = true;
      tests.cdk-mintd-backup-shutdown = true;
      # Boot without the legacy activation script that creates /var/lib/nixos.
      services.userborn.enable = true;
      # Supply secrets once; recovery must repair setup-secrets after restoring
      # a missing secret, and cannot depend on /secrets being in the archive.
      nix-bitcoin.generateSecrets = mkForce false;
      nix-bitcoin.setupSecrets = true;
      systemd.services.supply-test-secrets = {
        requiredBy = [ "setup-secrets.service" ];
        before = [ "setup-secrets.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          install -d -m 0700 /secrets
          cd /secrets
          ${config.nix-bitcoin.generateSecretsScript}
        '';
      };
      services.cdk-mintd.onchain.enable = true;
      services.cdk-mintd.settings.bdk.num_confs = 1;
      services.cdk-mintd.settings.bdk.wallet_rescan_from_height = 0;
      # Exercise the configured service group independently of the passwd group.
      services.cdk-mintd.group = "mint-service";
      users.users.cdk-mintd.group = mkForce "mint-login";
      users.groups.mint-login = {};
      services.backups.enable = true;
      # The general backup fixture is mainnet-only and creates its own wallet.
      tests.backups = mkForce false;
      # Even an extraFiles entry must not include the live mint or partial copies.
      services.backups.extraFiles = [ config.services.cdk-mintd.dataDir "/var/lib/cdk-mintd-backup" ];
      environment.systemPackages = [ pkgs.sqlite ];
      security.pam.loginLimits = [{ domain = "*"; type = "-"; item = "nofile"; value = "4096"; }];
      systemd.services.cdk-mintd-backup.serviceConfig.LimitNOFILE = 1024;
      systemd.services.cdk-mintd-backup.serviceConfig.TimeoutStartSec = mkForce "45s";
      test.data.cdk-mintd-recovery-pre-start = config.nix-bitcoin.lib.script "cdk-wallet-recovery" (
        (extendModules { modules = [{ services.cdk-mintd.onchain.allowNewWallet = mkForce true; }]; })
          .config.systemd.services.cdk-mintd.preStart
      );
      test.data.cdk-mintd-ipv6-pre-starts = map (address: (extendModules { modules = [{
        services.cdk-mintd = { backend = mkForce "lnd"; address = mkForce "::"; };
        services.lnd.rpcAddress = mkForce address;
        services.bitcoind.rpc.address = mkForce address;
      }]; }).config.systemd.services.cdk-mintd.preStart) [ "::" "[::]" "::1" "[::1]" ];
      # Pause copying deterministically to test starts and cancellation mid-backup.
      systemd.services.cdk-mintd-backup.path = mkBefore [
        (pkgs.writeShellScriptBin "systemctl" ''
          if [[ $1 == is-active && $2 == cdk-mintd.service && -e $STATE_DIRECTORY/pause-before-state-check ]]; then
            touch "$STATE_DIRECTORY/before-state-checked"
            while [[ -e $STATE_DIRECTORY/pause-before-state-check ]]; do sleep 0.1; done
          fi
          # Inject a backend start after the snapshot of the mint's state.
          if [[ $1 == is-active && $2 == cdk-mintd.service && -e $STATE_DIRECTORY/pause-state-check ]]; then
            status=0
            ${config.systemd.package}/bin/systemctl "$@" || status=$?
            touch "$STATE_DIRECTORY/state-checked"
            while [[ -e $STATE_DIRECTORY/pause-state-check ]]; do sleep 0.1; done
            exit "$status"
          fi
          if [[ $1 == try-restart || $1 == stop ]]; then
            # Hold a rejected transaction while the driver checks that existing
            # start/reload jobs survive. The next attempt uses real systemd.
            status=0
            if [[ $1 == try-restart && -e $STATE_DIRECTORY/reject-restart ]]; then
              status=1
            else
              ${config.systemd.package}/bin/systemctl "$@" || status=$?
            fi
            statusFile="$STATE_DIRECTORY/''${1#try-}-status"
            echo "$status" > "$statusFile.next"
            mv -T "$statusFile.next" "$statusFile"
            exit "$status"
          fi
          exec ${config.systemd.package}/bin/systemctl "$@"
        '')
        (pkgs.writeShellScriptBin "tar" ''
          while [[ -e ${config.services.cdk-mintd.dataDir}/pause-backup ]]; do sleep 0.1; done
          exec ${pkgs.gnutar}/bin/tar "$@"
        '')
      ];
    };

    unbeholden-lnurl-lnd = { config, ... }: {
      imports = [ scenarios.regtestBase ];
      # Exercise both gRPC clients with the IPv6 wildcard in LND's certificate.
      services.lnd.rpcAddress = mkDefault "::";
      services.charge-lnd.enable = config.services.unbeholden-lnurl.backend == "lnd";
      services.unbeholden-lnurl = {
        enable = true;
        backend = "lnd";
        settings.addresses.test = {
          description = "Bitcoinix test";
          min_sendable = 1000;
          max_sendable = 1000000;
        };
      };
    };

    unbeholden-lnurl-cln = {
      imports = [ scenarios.unbeholden-lnurl-lnd ];
      services.unbeholden-lnurl.backend = lib.mkForce "clightning";
    };

    unbeholden-lnurl-lnd-netns = {
      imports = with scenarios; [ unbeholden-lnurl-lnd netnsBase ];
    };

    unbeholden-lnurl-cln-netns = {
      imports = with scenarios; [ unbeholden-lnurl-cln netnsBase ];
    };

    unbeholden-lnurl-lnd-tor = {
      imports = [ scenarios.unbeholden-lnurl-lnd ../modules/presets/enable-tor.nix ];
      nix-bitcoin.onionServices.unbeholden-lnurl.enable = true;
    };

    unbeholden-lnurl-cln-tor = {
      imports = [ scenarios.unbeholden-lnurl-cln ../modules/presets/enable-tor.nix ];
      nix-bitcoin.onionServices.unbeholden-lnurl.enable = true;
    };

    unbeholden-wallet-electrs-netns = {
      imports = with scenarios; [ regtestBase netnsBase ];
      services.unbeholden-wallet.enable = true;
      services.unbeholden-wallet.allowedHosts = [ "wallet.test" ];
    };

    unbeholden-wallet-fulcrum-netns = {
      imports = [ scenarios.unbeholden-wallet-electrs-netns ];
      services.unbeholden-wallet.electrumServer = "fulcrum";
    };

    unbeholden-wallet-electrs = {
      imports = [ scenarios.regtestBase ];
      services.unbeholden-wallet = {
        enable = true;
        allowedHosts = [ "wallet.test" ];
        address = "0.0.0.0";
        allowedClients = [ "192.0.2.1" "192.0.2.0/24" ];
      };
      test.data.unbeholden-wallet-clients = { allowed = "192.0.2.1"; denied = "198.51.100.1"; };
    };

    unbeholden-wallet-fulcrum = {
      imports = [ scenarios.unbeholden-wallet-electrs ];
      services.unbeholden-wallet.electrumServer = "fulcrum";
    };

    # Unstable i2pd's build-time check cannot bind the namespace bridge address.
    # Exercise the actual SAM listener at runtime instead.
    i2p = {
      imports = [ scenarios.netnsBase scenarios.i2pLocal ];
      # Exercise configurable SAM ports and bridge addresses too.
      nix-bitcoin.netns-isolation.addressblock = 7;
      services.i2pd.settings.sam.port = 7657;
    };

    i2pLocal = {
      services.bitcoind = { enable = true; i2p = true; };
      # The test only needs SAM; no reseed servers are reachable offline.
      services.i2pd.settings.reseed = { urls = ""; yggurls = ""; };
    };

    # BTCPay Server on Core Lightning joins group clightning to use the RPC socket
    btcpayserverClightning = {
      imports = [ scenarios.regtestBase ];
      services.btcpayserver = {
        enable = true;
        lightningBackend = "clightning";
      };
    };

    # Test the special bitcoin RPC setup that lnd uses when bitcoin is pruned
    lndPruned = {
      services.lnd.enable = true;
      services.bitcoind.prune = 1000;
    };

    # Without netns-isolation, systemd listens on RTL's address. The node's kernel
    # decides whether systemd can listen on an IPv6 address, so test one in the VM.
    rtlIPv6.services.rtl = {
      enable = true;
      address = "::1";
      nodes.clightning.enable = false;
    };

    # The bitcoind group can read the blocks dir. This disables the bitcoind
    # wallet, which the regtest scenarios and the backups test need.
    # The test restarts bitcoind often, which would also stop the services that
    # depend on it, so this scenario runs only bitcoind and its tests.
    bitcoindGroupRead = {
      services.bitcoind = {
        network = "regtest";
        dataDirReadableByGroup = true;
      };
      # Groups with ACL entries on the blocks dir, like those of a backup tool
      users.groups = { blockbackup = {}; blockwriter = {}; };
      tests = mkForce {
        bitcoind = true;
        bitcoind-group-read = true;
      };
    };

    trustedcoin = {
      imports = [ scenarios.regtestBase ];

      services.clightning = {
        enable = true;
        plugins.trustedcoin.enable = true;
      };
    };
  } // (import ../dev/dev-scenarios.nix {
    inherit lib scenarios;
  });

  ## Example scenarios that showcase extra features
  exampleScenarios = with lib; {
    # Run a selection of tests in scenario 'netns'
    selectedTests = {
      imports = [ scenarios.netns ];
      tests = mkForce {
        btcpayserver = true;
        netns-isolation = true;
      };
    };

    # Container-specific features
    containerFeatures = {
      # Container has WAN access and bitcoind connects to external nodes
      test.container.enableWAN = true;
      # See ./lib/test-lib.nix for a description
      test.container.exposeLocalhost = true;
    };

    ## Scenarios with a custom Python test

    # Variant 1: Define testing code that always runs
    customTestSimple = {
      networking.hostName = "myhost";

      # Variant 1: Define testing code that always runs
      test.extraTestScript = ''
        succeed("[[ $(hostname) == myhost ]]")
      '';
    };

    # Variant 2: Define a test that can be enabled/disabled
    # via the Nix module system.
    customTestExtended = {
      networking.hostName = "myhost";

      tests.hostName = true;
      test.extraTestScript = ''
        @test("hostName")
        def test_hostname():
            succeed("[[ $(hostname) == myhost ]]")
      '';
    };
  };
in {
  inherit scenarios;

  pkgs = flake: pkgs: rec {
    # A basic test using the nix-bitcoin test framework
    makeTestBasic = import ./lib/make-test.nix flake pkgs makeTestVM;

    # Wraps `makeTest` in NixOS' testing-python.nix so that the drv includes the
    # log output and the test driver
    makeTestVM = import ./lib/make-test-vm.nix pkgs;

    # A test using the nix-bitcoin test framework, with some helpful defaults
    makeTest = { name ? "nix-bitcoin-test", config }:
      makeTestBasic {
        inherit name;
        config = {
          imports = [
            scenarios.base
            config
          ];
          # Share the same pkgs instance among tests
          # Set priority slightly higher (i.e. to a slightly lower number) than `mkDefault`,
          # so that this module can be used with function `pkgs.nixos`, which already
          # sets `nixpkgs.pkgs` with prio `mkDefault`.
          nixpkgs.pkgs = lib.mkOverride 900 pkgs;
        };
      };

    # A test using the nix-bitcoin test framework, with defaults specific to nix-bitcoin
    makeTestNixBitcoin = { name, config }:
      makeTest {
        name = "nix-bitcoin-${name}";
        config = {
          imports = [ config ];
          test.shellcheckServices.sourcePrefix = toString ./..;
        };
      };

    makeTests = scenarios: let
      mainTests = builtins.mapAttrs (name: config:
        makeTestNixBitcoin { inherit name config; }
      ) scenarios;
    in
      {
        clightning-replication = import ./clightning-replication.nix makeTestVM pkgs;
        wireguard-lndconnect = import ./wireguard-lndconnect.nix makeTestVM pkgs;
      } // mainTests;

    tests = makeTests scenarios;

    ## Helper for ./run-tests.sh

    getTest = { name, extraScenariosFile ? null }:
      let
        tests = makeTests (scenarios // (
          lib.optionalAttrs (extraScenariosFile != null)
            (import extraScenariosFile {
              inherit scenarios lib pkgs;
              nix-bitcoin = flake;
            })
        ));
      in
        tests.${name} or (makeTestNixBitcoin {
          inherit name;
          config = {
            services.${name}.enable = true;
          };
        });

    instantiateTestsFromStr = testNamesStr: instantiateTests (lib.splitString " " testNamesStr);

    instantiateTests = testNames:
      map (name:
        let
          test = tests.${name};
        in
          builtins.seq (builtins.trace "Evaluating test '${name}'" test.outPath)
            test
      ) testNames;
  };
}
