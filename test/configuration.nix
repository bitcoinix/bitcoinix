# Configuration contracts that need evaluation, not a running node.
{ pkgs, nixBitcoinModule }:
let
  inherit (pkgs) lib;
  base = pkgs.nixos {
    imports = [ nixBitcoinModule ];
    boot.isContainer = true;
    system.stateVersion = "26.05";
    nix-bitcoin.secretsSetupMethod = "manual";
  };
  evaluate = module: (base.extendModules { modules = [ module ]; }).config;
  failedAssertions = config:
    map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);

  # These fixtures are independent of VM scenarios and their overrides.
  restAllowed = {
    enable ? true, allowNonLocal ? false, allowUncheckedConfig ? false,
    allowip ? [ "127.0.0.1" ], extraConfig ? ""
  }: let
    config = evaluate {
      services.bitcoind = {
        enable = true;
        rest = { inherit enable allowNonLocal allowUncheckedConfig; };
        rpc.allowip = allowip;
        inherit extraConfig;
      };
    };
  in !(lib.any (message: lib.hasInfix "bitcoind REST interface is unauthenticated" message)
    (failedAssertions config));
  lan = { allowip = [ "10.10.0.0/24" ]; };
  raw = { extraConfig = "rpcallowip=10.10.0.0/24\nincludeconf=/etc/bitcoin-extra.conf"; };
  restCases = {
    localhost = { args.allowip = [ "127.0.0.1" "::1" ]; expected = true; };
    lanRefused = { args = lan; expected = false; };
    lanOptIn = { args = lan // { allowNonLocal = true; }; expected = true; };
    loopbackCidrs = { args.allowip = [ "127.0.0.0/8" "127.0.0.1/32" "::1/128" ]; expected = true; };
    broadIPv4 = { args.allowip = [ "127.0.0.0/7" ]; expected = false; };
    broadIPv6 = { args.allowip = [ "::1/127" ]; expected = false; };
    rawAllowip = { args.extraConfig = "rpcbind=0.0.0.0\nrpcallowip=10.10.0.0/24"; expected = false; };
    rawWhitespace = { args.extraConfig = " \trpcallowip = 10.10.0.0/24 # LAN\r"; expected = false; };
    rawSection = { args.extraConfig = "regtest.rpcallowip=10.10.0.0/24"; expected = false; };
    rawInclude = { args.extraConfig = "[main]\nincludeconf=/etc/bitcoin-extra.conf"; expected = false; };
    rawOptIn = { args = raw // { allowNonLocal = true; }; expected = true; };
    rawUnchecked = { args = raw // { allowUncheckedConfig = true; }; expected = true; };
    rawUncheckedKeepsAllowip = { args = raw // lan // { allowUncheckedConfig = true; }; expected = false; };
    rawRestDisabled = { args = raw // { enable = false; }; expected = true; };
    rawComments = {
      args.extraConfig = "# rpcallowip=10.10.0.0/24\n  # regtest.includeconf=extra.conf\nconnect=0 # rpcallowip";
      expected = true;
    };
    rawNegated = { args.extraConfig = "norpcallowip=0"; expected = false; };
    rawNegatedInclude = { args.extraConfig = "regtest.noincludeconf=0"; expected = false; };
  };

  bitcoin = evaluate { services.bitcoind.enable = true; };
  regtest = evaluate { services.bitcoind = { enable = true; regtest = true; }; };
  electrs = evaluate { services.electrs.enable = true; };
  prunedElectrs = evaluate {
    services.electrs.enable = true;
    services.bitcoind.prune = 1000;
  };
  lightning = {
    services.lnd = { enable = true; lndconnect.enable = true; };
    services.clightning = {
      enable = true;
      plugins.clnrest = { enable = true; lnconnect.enable = true; };
    };
  };
  conflictingLightning = evaluate lightning;
  localLightning = evaluate {
    imports = [ lightning ];
    services.lnd.port = 9736;
  };
  customLightning = evaluate {
    imports = [ lightning ];
    services.lnd = { port = 9736; restAddress = "10.0.0.2"; };
    services.clightning.plugins.clnrest.address = "10.0.0.3";
  };
  netns = evaluate {
    imports = [ lightning ];
    services.lnd.port = 9736;
    services.electrs.enable = true;
    nix-bitcoin.netns-isolation.enable = true;
  };
  netnsNftables = evaluate {
    services.bitcoind.enable = true;
    nix-bitcoin.netns-isolation.enable = true;
    networking.nftables.enable = true;
  };
  netnsNftablesIptablesBackend = evaluate {
    services.bitcoind.enable = true;
    nix-bitcoin.netns-isolation.enable = true;
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
  };
  netnsNftablesIptablesPackage = evaluate {
    services.bitcoind.enable = true;
    nix-bitcoin.netns-isolation.enable = true;
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.iptables;
  };
  customMempoolUser = evaluate {
    services.mempool = { enable = true; user = "mempool-custom"; };
  };
  customClightningUser = evaluate {
    services.clightning = {
      enable = true;
      user = "cln-custom";
      dataDir = "/var/lib/cln custom";
      plugins.feeadjuster = { enable = true; adjustDaily = true; };
    };
  };
  lndconnectOnion = {
    services.lnd = { enable = true; lndconnect = { enable = true; onion = true; }; };
  };
  lndconnectNoOperator = evaluate lndconnectOnion;
  lndconnectWithOperator = evaluate {
    imports = [ lndconnectOnion ];
    nix-bitcoin.operator.enable = true;
  };
  lnconnectNoOperator = evaluate {
    services.clightning = {
      enable = true;
      plugins.clnrest = { enable = true; lnconnect = { enable = true; onion = true; }; };
    };
  };
  # An existing account named as the operator, with the operator role disabled
  operatorAccountOnion = {
    imports = [ lndconnectOnion ];
    users.users.alice.isNormalUser = true;
    nix-bitcoin.operator.name = "alice";
    services.clightning = {
      enable = true;
      # Don't conflict with the lnd p2p port
      port = 9736;
      plugins.clnrest = { enable = true; lnconnect = { enable = true; onion = true; }; };
    };
  };
  operatorAccountRoleDisabled = evaluate operatorAccountOnion;
  operatorAccountExplicitAccess = evaluate {
    imports = [ operatorAccountOnion ];
    nix-bitcoin.onionAddresses.access.alice = [ "lnd-rest" "clnrest" ];
  };
  onionAccessUnknownUser = evaluate {
    nix-bitcoin.onionAddresses.access."no-such-user" = [ "bitcoind" ];
  };
  getOnionAccessUsers = config:
    lib.sort lib.lessThan (builtins.attrNames config.nix-bitcoin.onionAddresses.access);
  getBitcoinDefaults = config: with config.services.bitcoind; {
    inherit network port listen;
    rpc = { inherit (rpc) address port allowip; };
    rest = { inherit (rest) enable allowNonLocal allowUncheckedConfig; };
  };
  getRestAddresses = config: [
    config.services.lnd.restAddress
    config.services.clightning.plugins.clnrest.address
  ];

  extraConfigFixtures = map (service: {
    name = service;
    enablePath = [ "services" service "enable" ];
    optionPath = [ "services" service "extraConfig" ];
    value = "bitcoinix-test-private-setting=1";
    empty = "";
    module = {};
  }) [ "bitcoind" "clightning" "lnd" "fulcrum" ] ++ map (node: {
    name = "rtl-${node}";
    enablePath = [ "services" "rtl" "nodes" node "enable" ];
    optionPath = [ "services" "rtl" "nodes" node "extraConfig" ];
    value.Settings.logLevel = "bitcoinix-test-private-setting";
    empty = {};
    module.services.rtl.enable = true;
  }) [ "clightning" "lnd" ];
  extraConfigTests = lib.listToAttrs (lib.concatMap (fixture:
    map (case: lib.nameValuePair "testExtraConfig-${fixture.name}-${case.name}" {
      expr = let
        config = evaluate {
          imports = [
            fixture.module
            (lib.setAttrByPath fixture.enablePath case.enable)
            (lib.setAttrByPath fixture.optionPath case.value)
          ];
        };
        warnings = builtins.filter
          (lib.hasInfix "${lib.concatStringsSep "." fixture.optionPath} is non-empty.")
          config.warnings;
      in {
        count = builtins.length warnings;
        explainsResponsibility = lib.all (lib.hasInfix "responsibility") warnings;
        explainsUnsupported = lib.all (lib.hasInfix "unsupported by bitcoinix") warnings;
        keepsContentsPrivate = lib.all
          (warning: !(lib.hasInfix "bitcoinix-test-private-setting" warning)) warnings;
      };
      expected = {
        count = case.count;
        explainsResponsibility = true;
        explainsUnsupported = true;
        keepsContentsPrivate = true;
      };
    }) [
      { name = "populated"; enable = true; value = fixture.value; count = 1; }
      { name = "empty"; enable = true; value = fixture.empty; count = 0; }
      { name = "disabled"; enable = false; value = fixture.value; count = 0; }
    ]
  ) extraConfigFixtures);
  # Modules that write config lines themselves must not trigger the warning
  extraConfigWarnings = option: config: builtins.filter
    (lib.hasInfix "${option} is non-empty.") config.warnings;
  clightningPlugins = [
    "clboss" "clnrest" "feeadjuster" "trustedcoin" "zmq" "currencyrate" "monitor" "rebalance"
  ];
  pluginsConfigTests = lib.listToAttrs (map (plugin:
    lib.nameValuePair "testExtraConfig-clightning-plugin-${plugin}" {
      expr = map (lib.hasInfix "bitcoinix-test-private-setting") (lib.concatMap (extraConfig:
        extraConfigWarnings "services.clightning.extraConfig" (evaluate {
          services.clightning = {
            enable = true;
            plugins.${plugin}.enable = true;
            inherit extraConfig;
          };
        })
      ) [ "" "bitcoinix-test-private-setting=1" ]);
      expected = [ false ];
    }) clightningPlugins) // {
    testExtraConfig-bitcoind-remote-preset = {
      expr = let
        config = evaluate {
          imports = [ ../modules/presets/bitcoind-remote.nix ];
          services.bitcoind.enable = true;
        };
      in {
        warnings = extraConfigWarnings "services.bitcoind.extraConfig" config;
        rpcuser = lib.hasInfix "rpcuser=privileged" config.systemd.services.bitcoind.preStart;
      };
      expected = { warnings = []; rpcuser = true; };
    };
  };
  # The preset's preStart lines, run by the check below against a scratch data dir
  remoteRpcUser = "rpc$USER'$(id)";
  remotePresetPreStart = pkgs.writeText "bitcoind-remote-prestart"
    (import ../modules/presets/bitcoind-remote.nix {
      inherit lib pkgs;
      config = {
        services.bitcoind = { dataDir = "@dataDir@"; rpc.users.privileged.name = remoteRpcUser; };
        nix-bitcoin.secretsDir = "@secretsDir@";
      };
    }).systemd.services.bitcoind.preStart.content;

  tests = lib.mapAttrs' (name: case: lib.nameValuePair "testREST-${name}" {
    expr = restAllowed case.args;
    inherit (case) expected;
  }) restCases // extraConfigTests // pluginsConfigTests // {
    testBitcoinDefaults = {
      expr = getBitcoinDefaults bitcoin;
      expected = {
        network = "mainnet";
        port = 8333;
        listen = false;
        rpc = { address = "127.0.0.1"; port = 8332; allowip = [ "127.0.0.1" ]; };
        rest = { enable = false; allowNonLocal = false; allowUncheckedConfig = false; };
      };
    };
    testRegtestDefaults = {
      expr = getBitcoinDefaults regtest;
      expected = tests.testBitcoinDefaults.expected // {
        network = "regtest";
        port = 18444;
        rpc = tests.testBitcoinDefaults.expected.rpc // { port = 18443; };
      };
    };
    testElectrsEnablesBitcoinREST = {
      expr = with electrs.services.bitcoind; [ enable rest.enable ];
      expected = [ true true ];
    };
    testElectrsUnpruned = { expr = failedAssertions electrs; expected = []; };
    testElectrsRejectsPruning = {
      expr = failedAssertions prunedElectrs;
      expected = [ "electrs does not support bitcoind pruning." ];
    };
    testLightningRejectsPortCollision = {
      expr = map (lib.hasInfix "LND and clightning can't both bind")
        (failedAssertions conflictingLightning);
      expected = [ true ];
    };
    testLightningSeparatePorts = { expr = failedAssertions localLightning; expected = []; };
    testLndconnectKeepsLocalAddresses = {
      expr = getRestAddresses localLightning;
      expected = [ "127.0.0.1" "127.0.0.1" ];
    };
    testLndconnectKeepsCustomAddresses = {
      expr = getRestAddresses customLightning;
      expected = [ "10.0.0.2" "10.0.0.3" ];
    };
    testNetnsRESTAllowed = { expr = failedAssertions netns; expected = []; };
    testNetnsRejectsNftables = {
      expr = map (lib.hasInfix "uses the iptables backend") (failedAssertions netnsNftables);
      expected = [ true ];
    };
    testNetnsRejectsNftablesWithIptablesBackend = {
      expr = map (lib.hasInfix "uses the iptables backend") (failedAssertions netnsNftablesIptablesBackend);
      expected = [ true ];
    };
    testNetnsAllowsNftablesWithIptablesPackage = {
      expr = failedAssertions netnsNftablesIptablesPackage;
      expected = [];
    };
    testNetnsRESTAddresses = {
      expr = getRestAddresses netns;
      expected = with netns.nix-bitcoin.netns-isolation.netns; [ lnd.address clightning.address ];
    };
    testLndconnectWithoutOperator = {
      expr = {
        failed = failedAssertions lndconnectNoOperator;
        users = getOnionAccessUsers lndconnectNoOperator;
      };
      expected = { failed = []; users = [ lndconnectNoOperator.services.lnd.user ]; };
    };
    testLndconnectWithOperator = {
      expr = getOnionAccessUsers lndconnectWithOperator;
      expected = with lndconnectWithOperator;
        lib.sort lib.lessThan [ services.lnd.user nix-bitcoin.operator.name ];
    };
    testLnconnectOnionRequiresOperator = {
      expr = map (lib.hasInfix "nix-bitcoin.operator.enable")
        (failedAssertions lnconnectNoOperator);
      expected = [ true ];
    };
    testOperatorAccountGetsNoAutomaticAccess = {
      expr = {
        users = getOnionAccessUsers operatorAccountRoleDisabled;
        lnconnectFails = map (lib.hasInfix "lnconnect.onion")
          (failedAssertions operatorAccountRoleDisabled);
      };
      expected = {
        users = [ operatorAccountRoleDisabled.services.lnd.user ];
        lnconnectFails = [ true ];
      };
    };
    testOperatorAccountExplicitAccess = {
      expr = with operatorAccountExplicitAccess; {
        failed = failedAssertions operatorAccountExplicitAccess;
        alice = nix-bitcoin.onionAddresses.access.alice;
      };
      expected = { failed = []; alice = [ "lnd-rest" "clnrest" ]; };
    };
    testOnionAccessRejectsUnknownUser = {
      expr = map (lib.hasInfix "no-such-user") (failedAssertions onionAccessUnknownUser);
      expected = [ true ];
    };
    testMempoolCustomUser = {
      expr = with customMempoolUser; {
        service = systemd.services.mempool.serviceConfig.User;
        database = services.mempool.settings.DATABASE.USERNAME or null;
        mysql = map (user: user.name) services.mysql.ensureUsers;
      };
      expected = {
        service = "mempool-custom";
        database = "mempool-custom";
        mysql = [ "mempool-custom" ];
      };
    };
    testFeeadjusterFollowsClightningUser = {
      expr = with customClightningUser.systemd.services.clightning-feeadjuster.serviceConfig; {
        user = User;
        quotedDataDir = lib.hasInfix "--lightning-dir '/var/lib/cln custom' feeadjust" ExecStart;
      };
      expected = { user = "cln-custom"; quotedDataDir = true; };
    };
  };
  failures = lib.debug.runTests tests;
in
if failures != [] then
  throw "Configuration tests failed: ${builtins.toJSON failures}"
else
  pkgs.runCommand "nix-bitcoin-configuration-tests" {
    passthru.testCount = builtins.length (builtins.attrNames tests);
  } ''
    mkdir data secrets
    echo secret > secrets/bitcoin-rpcpassword-privileged
    sed -e "s|@dataDir@|$PWD/data|g; s|@secretsDir@|$PWD/secrets|g" ${remotePresetPreStart} > prestart.sh
    USER=bitcoin bash -eu prestart.sh
    if ! grep -qFx ${lib.escapeShellArg "rpcuser=${remoteRpcUser}"} data/bitcoin.conf; then
      echo "bitcoind-remote preset doesn't preserve the RPC username:" >&2
      cat data/bitcoin.conf >&2
      exit 1
    fi

    echo '${toString (builtins.length (builtins.attrNames tests))} configuration tests passed' > "$out"
  ''
