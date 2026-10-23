# Integration tests, can be run without internet access.

lib: nixBitcoinModule:
let
  # Included in all scenarios
  baseConfig = { config, pkgs, extendModules, ... }: with lib; let
    cfg = config.services;
    inherit (config.nix-bitcoin.lib.test) mkIfTest;
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
        # Needed to trace the commands run by secret generation
        (mkIfTest "secrets-no-argv" [ strace ])
        # Needed to call the barkd REST API
        (mkIfTest "barkd" [ curl ])
      ]);

      tests.bitcoind = cfg.bitcoind.enable;

      tests.secrets-no-argv = cfg.bitcoind.enable;
      test.data.secrets-no-argv.generator = "${config.nix-bitcoin.generateSecretsScript}";

      tests.rpc-whitelist = cfg.bitcoind.enable;
      # Which consumers are enabled decides which extra methods they may grant
      test.data.rpc-whitelist = {
        btcpayserver = cfg.btcpayserver.enable;
        clightning-bcli = cfg.clightning.enable && cfg.clightning.useBcliPlugin;
        mempool = cfg.mempool.enable;
        barkd = cfg.barkd.enable && cfg.barkd.chainSource == "bitcoind";
      };

      tests.bitcoind-rest = cfg.bitcoind.enable;
      test.data.bitcoind-rest = let
        # Keep fixture values independent of the scenario, including mkForce.
        restAllowed = {
          enable ? true, allowNonLocal ? false, allowUncheckedConfig ? false,
          allowip ? [ "127.0.0.1" ], extraConfig ? ""
        }: let
          extended = extendModules {
            modules = [{
              services.bitcoind.rest.enable = mkOverride 0 enable;
              services.bitcoind.rest.allowNonLocal = mkOverride 0 allowNonLocal;
              services.bitcoind.rest.allowUncheckedConfig = mkOverride 0 allowUncheckedConfig;
              services.bitcoind.rpc.allowip = mkOverride 0 allowip;
              services.bitcoind.extraConfig = mkOverride 0 extraConfig;
            }];
          };
        in !(any (a: !a.assertion && hasInfix "bitcoind REST interface is unauthenticated" a.message)
          extended.config.assertions);
        lan = { allowip = [ "10.10.0.0/24" ]; };
        raw = { extraConfig = "rpcallowip=10.10.0.0/24\nincludeconf=/etc/bitcoin-extra.conf"; };
        cases = {
          localhost = restAllowed { allowip = [ "127.0.0.1" "::1" ]; };
          lanRefused = !restAllowed lan;
          lanOptIn = restAllowed (lan // { allowNonLocal = true; });
          loopbackCidrs = restAllowed { allowip = [ "127.0.0.0/8" "127.0.0.1/32" "::1/128" ]; };
          broadIPv4 = !restAllowed { allowip = [ "127.0.0.0/7" ]; };
          broadIPv6 = !restAllowed { allowip = [ "::1/127" ]; };
          rawAllowip = !restAllowed { extraConfig = "rpcbind=0.0.0.0\nrpcallowip=10.10.0.0/24"; };
          rawWhitespace = !restAllowed { extraConfig = " \trpcallowip = 10.10.0.0/24 # LAN\r"; };
          rawSection = !restAllowed { extraConfig = "regtest.rpcallowip=10.10.0.0/24"; };
          rawInclude = !restAllowed { extraConfig = "[main]\nincludeconf=/etc/bitcoin-extra.conf"; };
          rawOptIn = restAllowed (raw // { allowNonLocal = true; });
          rawUnchecked = restAllowed (raw // { allowUncheckedConfig = true; });
          rawUncheckedKeepsAllowip = !restAllowed (raw // lan // { allowUncheckedConfig = true; });
          rawRestDisabled = restAllowed (raw // { enable = false; });
          rawComments = restAllowed {
            extraConfig = "# rpcallowip=10.10.0.0/24\n  # regtest.includeconf=extra.conf\nconnect=0 # rpcallowip";
          };
        };
      in {
        inherit (cfg.bitcoind.rest) enable;
        rpcPort = cfg.bitcoind.rpc.port;
        failedCases = attrNames (filterAttrs (_: passed: !passed) cases);
      };

      services.bitcoind = {
        enable = true;
        extraConfig = mkIf config.test.noConnections "connect=0";
      };

      tests.clightning = cfg.clightning.enable;
      test.data.clightning-replication = cfg.clightning.replication.enable;
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
          clnrest.path = "${plugins.clnrest.package}/bin/clnrest";
          trustedcoin.path = "${plugins.trustedcoin.package}/bin/trustedcoin";
        };
      in map (plugin: pluginPkgs.${plugin}.path) enabled;

      tests.rtl = cfg.rtl.enable;
      tests.rtl-credentials = cfg.rtl.enable;
      test.data.rtl-credentials = {
        inherit (cfg.rtl) dataDir user group;
        lnd = if cfg.rtl.nodes.lnd.enable then { inherit (cfg.lnd) networkDir user; } else null;
        clightning = if cfg.rtl.nodes.clightning.enable then { inherit (cfg.clightning) networkDir user; } else null;
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

      tests.lnd = cfg.lnd.enable;
      tests.lnd-macaroons = cfg.lnd.enable && cfg.lnd.macaroons != {};
      test.data.lnd-macaroons = {
        inherit (cfg.lnd) networkDir user;
        users = mapAttrs (_: macaroon: macaroon.user) cfg.lnd.macaroons;
      };
      services.lnd = {
        port = 9736;
        certificate = {
          extraIPs = [ "10.0.0.1" "20.0.0.1" ];
          extraDomains = [ "example.com" ];
        };
      };

      nix-bitcoin.onionServices.lnd.public = true;

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

      # Config files in dirs writable by the operator or service user.
      # `planter` is the user that plants the replacement file.
      tests.config-replace = config.test.data.config-replace != [];
      test.data.config-replace =
        optional cfg.bitcoind.enable {
          unit = "bitcoind";
          file = "${cfg.bitcoind.dataDir}/bitcoin.conf";
          mode = "640";
          inherit (cfg.bitcoind) user;
          planter = config.nix-bitcoin.operator.name;
        }
        ++ optional cfg.clightning.enable {
          unit = "clightning";
          file = "${cfg.clightning.dataDir}/config";
          mode = "640";
          inherit (cfg.clightning) user;
          planter = config.nix-bitcoin.operator.name;
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
        ++ optional cfg.barkd.enable {
          unit = "barkd";
          file = "${cfg.barkd.dataDir}/config.toml";
          mode = "600";
          inherit (cfg.barkd) user;
          planter = cfg.barkd.user;
        }
        ++ optional cfg.mempool.enable {
          unit = "mempool";
          file = config.systemd.services.mempool.environment.MEMPOOL_CONFIG_FILE;
          mode = "600";
          inherit (cfg.mempool) user;
          planter = cfg.mempool.user;
        };

      tests.charge-lnd = cfg.charge-lnd.enable;

      tests.barkd = cfg.barkd.enable;
      test.data.barkd = {
        inherit (cfg.barkd) dataDir user port network chainSource;
      };
      # There is no Ark server in the test VMs, so wallet creation would fail.
      # The barkd test creates a wallet via the REST API instead.
      services.barkd.createWallet = mkDefault false;

      tests.electrs = cfg.electrs.enable;

      services.fulcrum.port = 50002;
      tests.fulcrum = cfg.fulcrum.enable;

      tests.btcpayserver = cfg.btcpayserver.enable;
      services.btcpayserver.lightningBackend = mkDefault "lnd";

      tests.nodeinfo = config.nix-bitcoin.nodeinfo.enable;

      tests.backups = cfg.backups.enable;

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

  scenarios = with lib; {
    # Included in all scenarios by ./lib/make-test.nix
    base = baseConfig;

    default = scenarios.secureNode;

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
      services.electrs.enable = true;
      services.fulcrum.enable = true;
      services.btcpayserver.enable = true;
      # Uses the default signet Ark server and Esplora instance (unreachable in tests)
      services.barkd.enable = true;
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
      services.lnd.enable = true;
      services.lnd.lndconnect.enable = true;
      services.charge-lnd.enable = true;
      services.electrs.enable = true;
      services.fulcrum.enable = true;
      services.btcpayserver.enable = true;
      services.barkd = {
        enable = true;
        network = "regtest";
        chainSource = "bitcoind";
        # Not running. The barkd test checks that wallet creation gets past
        # the chain source checks and then fails to reach this server.
        arkServer = "http://127.0.0.1:3535";
      };
    };

    # netns and regtest, without secure-node.nix
    netnsRegtest = {
      imports = with scenarios; [ netnsBase regtest ];
    };

    hardened = {
      imports = [
        scenarios.secureNode
        ../modules/presets/hardened-extended.nix
      ];
    };

    netnsBase = { config, pkgs, ... }: {
      nix-bitcoin.netns-isolation.enable = true;
      test.data.netns = config.nix-bitcoin.netns-isolation.netns;
      tests.netns-isolation = true;
      environment.systemPackages = [ pkgs.fping ];
    };

    regtestBase = { config, pkgs, ... }: {
      tests.regtest = true;
      # On regtest, electrs is live at this point and the Lightning daemons
      # are synced, so the restart test covers fully running dependents.
      tests.restart-bitcoind = true;
      tests.lnd-restart-on-clean-exit = config.services.lnd.enable;
      test.data.num_blocks = 100;

      services.bitcoind.regtest = true;
      systemd.services.bitcoind.postStart = mkAfter ''
        cli=${config.services.bitcoind.cli}/bin/bitcoin-cli
        if ! $cli listwallets | ${pkgs.jq}/bin/jq -e 'index("test")'; then
          "$cli" -named createwallet  wallet_name=test load_on_startup=true
          address=$($cli -rpcwallet=test getnewaddress)
          "$cli" generatetoaddress ${toString config.test.data.num_blocks} "$address"
        fi
      '';
    };

    # Test the special bitcoin RPC setup that lnd uses when bitcoin is pruned
    lndPruned = {
      services.lnd.enable = true;
      services.bitcoind.prune = 1000;
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
        def _():
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
