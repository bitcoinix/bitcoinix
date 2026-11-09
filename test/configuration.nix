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
  backupsWithCompression = compression: evaluate {
    services.btcpayserver.enable = true;
    services.backups.enable = true;
    services.postgresqlBackup.compression = compression;
  };
  # What lnd's config appends to the announced address
  lndAddressSuffix = module: let
    config = evaluate {
      imports = [ module ];
      services.lnd = { enable = true; port = 9736; };
    };
    externalip = lib.findFirst (lib.hasInfix "externalip=") ""
      (lib.splitString "\n" config.systemd.services.lnd.preStart);
  in lib.head (builtins.match ''.*externalip=\$\(.*\)(.*)"'' externalip);
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
  mempool = evaluate { services.mempool.enable = true; };
  mempoolRpcPassword = evaluate {
    services.mempool = {
      enable = true;
      settings.CORE_RPC.PASSWORD = lib.mkForce "literal-password";
    };
  };
  wireguardLndconnect = {
    imports = [ ../modules/presets/wireguard.nix ];
    services.lnd = { enable = true; lndconnect.enable = true; };
  };
  wireguardNftablesIptablesBackend = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
  };
  wireguardNftablesIptables = {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.iptables;
  };
  wireguardNftablesIptablesPackage = evaluate wireguardNftablesIptables;
  wireguardNftablesIptablesExtraPackage = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.extraPackages = [ pkgs.iptables ];
  };
  wireguardNftablesRuleset = evaluate {
    imports = [ wireguardNftablesIptables ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  wireguardNftablesOldStateVersion = evaluate {
    imports = [ wireguardNftablesIptables ];
    system.stateVersion = lib.mkForce "23.05";
  };
  wireguardNftablesTables = evaluate {
    imports = [ wireguardNftablesIptables ];
    networking.nftables.tables.extra = { family = "inet"; content = ""; };
  };
  wireguardNftablesIptablesTable = evaluate {
    imports = [ wireguardNftablesIptables ];
    networking.nftables.tables.filter = { family = "ip"; content = ""; };
  };
  wireguardNftablesIptablesLegacy = {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.iptables-legacy;
  };
  wireguardNftablesIptablesLegacyRuleset = evaluate {
    imports = [ wireguardNftablesIptablesLegacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  wireguardNftablesIptablesLegacyTable = evaluate {
    imports = [ wireguardNftablesIptablesLegacy ];
    networking.nftables.tables.filter = { family = "ip"; content = ""; };
  };
  wireguardNftablesIptablesLegacyExtraPackageRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.extraPackages = [ pkgs.iptables-legacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  wireguardNftablesIptablesBeforeLegacyRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.extraPackages = [ pkgs.iptables pkgs.iptables-legacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  # An iptables-nft package under another name still runs first
  wireguardNftablesRenamedIptablesRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.iptables.overrideAttrs { pname = "iptables-nft"; };
    networking.firewall.extraPackages = [ pkgs.iptables-legacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  # The legacy build comes first on the PATH, so it runs
  wireguardNftablesIptablesAfterLegacyRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.extraPackages = [ pkgs.iptables-legacy pkgs.iptables ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  wireguardNftablesRenamedIptablesExtraPackageRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.extraPackages = [
      (pkgs.iptables.overrideAttrs { pname = "iptables-nft"; })
      pkgs.iptables-legacy
    ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  # An iptables-nft package under any other name counts as iptables-nft
  wireguardNftablesCustomIptablesRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.iptables.overrideAttrs { pname = "xtables-nft"; };
    networking.firewall.extraPackages = [ pkgs.iptables-legacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  # A wrapper without "tables" in its name
  wireguardNftablesWrappedIptablesRuleset = evaluate {
    imports = [ wireguardLndconnect ];
    networking.nftables.enable = true;
    networking.firewall.backend = "iptables";
    networking.firewall.package = pkgs.symlinkJoin { name = "fw-tools"; paths = [ pkgs.iptables ]; };
    networking.firewall.extraPackages = [ pkgs.iptables-legacy ];
    networking.nftables.ruleset = "table inet extra { }";
  };
  # The service's PATH replaced directly
  wireguardNftablesIptablesForcedPathRuleset = evaluate {
    imports = [ wireguardNftablesIptablesLegacy ];
    systemd.services.firewall.environment.PATH =
      lib.mkForce (lib.makeBinPath [ pkgs.iptables pkgs.coreutils ]);
    networking.nftables.ruleset = "table inet extra { }";
  };
  # PATH can be unset and come from serviceConfig.Environment instead
  wireguardNullPath = evaluate {
    imports = [ wireguardLndconnect ];
    systemd.services.firewall.environment.PATH = lib.mkForce null;
  };
  # iptables-nft added to the service PATH directly
  wireguardNftablesIptablesOnServicePathRuleset = evaluate {
    imports = [ wireguardNftablesIptablesLegacy ];
    systemd.services.firewall.path = lib.mkBefore [ pkgs.iptables ];
    networking.nftables.ruleset = "table inet extra { }";
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
  btcpayserverCustomClightningGroup = evaluate {
    services.btcpayserver = { enable = true; lightningBackend = "clightning"; };
    services.clightning = { user = "cln-custom"; group = "cln-rpc"; };
  };
  replicationHostKeyWarnings = replication: builtins.filter
    (lib.hasInfix "disables SSH host key checking")
    (evaluate {
      services.clightning = { enable = true; replication = { enable = true; } // replication; };
    }).warnings;
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
  # The same, with the account defined under an attribute that isn't its login name
  operatorRenamedAccountRoleDisabled = evaluate {
    imports = [ lndconnectOnion ];
    users.users.account = { name = "alice"; isNormalUser = true; };
    nix-bitcoin.operator.name = "alice";
    services.clightning = {
      inherit (operatorAccountOnion.services.clightning) enable port plugins;
    };
  };
  # The migration that docs/upgrading.md describes for a disabled role
  operatorAccountGrant = {
    imports = [ operatorAccountOnion ];
    nix-bitcoin.onionAddresses.access.alice = [ "clnrest" ];
    users.users.alice.extraGroups = [ "clightning" ];
  };
  operatorAccountExplicitAccess = evaluate operatorAccountGrant;
  # Whether a config written for the last release passes the versioning check
  passesVersionCheckAt = version: module: (builtins.tryEval (evaluate {
    imports = [ module ];
    nix-bitcoin.configVersion = version;
  }).system.stateVersion).success;
  # Whether a 0.1.5 config gets the notice whose message contains `phrase`.
  # The versioning throw is a definition of `system`, which the module check
  # forces on any config access, so skip the check here.
  hasNotice = phrase: module: lib.any (lib.hasInfix phrase) (evaluate {
    imports = [ module ];
    nix-bitcoin.configVersion = "0.1.5";
    _module.check = false;
  }).nix-bitcoin.versioning.incompatibleChanges;
  hasOperatorAccessNotice = hasNotice "lnconnect-clnrest now gives the operator user";
  hasAccessUsersNotice = hasNotice "now accepts only users that are defined";
  # A user that exists only outside `users.users`, for example via useradd or LDAP
  onionAccessExternalUser = {
    nix-bitcoin.onionAddresses.access.external-user = [ "bitcoind" ];
  };
  onionAccessUnknownUser = evaluate {
    nix-bitcoin.onionAddresses.access."no-such-user" = [ "bitcoind" ];
  };
  # The access key is a login name, which can differ from the attribute name
  onionAccessLoginName = {
    users.users.account = { name = "renamed-user"; isNormalUser = true; };
    nix-bitcoin.onionAddresses.access."renamed-user" = [ "bitcoind" ];
  };
  onionAccessRenamedUser = evaluate onionAccessLoginName;
  onionAccessDisabledUser = evaluate {
    users.users.disabled-user = { isNormalUser = true; enable = false; };
    nix-bitcoin.onionAddresses.access."disabled-user" = [ "bitcoind" ];
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
  pluginMigrationTests = lib.listToAttrs (map (plugin:
    lib.nameValuePair "testClightningPluginMigration-${plugin}" {
      expr = map (case: (builtins.tryEval (evaluate {
        nix-bitcoin.configVersion = case.version;
        services.clightning = {
          enable = true;
          plugins.${plugin}.enable = case.enable;
        };
      }).system.stateVersion).success) [
        { version = "0.1.4"; enable = true; }
        { version = "0.1.4"; enable = false; }
        { version = "0.1.5"; enable = true; }
        { version = null; enable = true; }
      ];
      expected = [ false true true true ];
    }) [ "currencyrate" "rebalance" ]);
  # Secret generation with the replication SSH key, run by the check below
  replicationGenerator = (evaluate {
    services.clightning = {
      enable = true;
      replication = { enable = true; sshfs.destination = "user@host:dir"; };
    };
  }).nix-bitcoin.generateSecretsScript;

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
  }) restCases // extraConfigTests // pluginsConfigTests // pluginMigrationTests // {
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
    testLndAnnouncesOnionPort = {
      expr = map lndAddressSuffix [
        { nix-bitcoin.onionServices.lnd.public = true; }
        { nix-bitcoin.onionServices.lnd = { public = true; externalPort = 9735; }; }
        # Another mapping before lnd's peer port
        {
          nix-bitcoin.onionServices.lnd.public = true;
          services.tor.relay.onionServices.lnd.map = lib.mkBefore [ { port = 8443; target.port = 8080; } ];
        }
        # A custom address may carry its own port
        { services.lnd.getPublicAddressCmd = "echo 203.0.113.10:19735"; }
      ];
      expected = [ ":9736" ":9735" ":9736" "" ];
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
    testWireguardRejectsNftablesWithIptablesBackend = {
      expr = map (lib.hasInfix "need `iptables` on the firewall service's PATH")
        (failedAssertions wireguardNftablesIptablesBackend);
      expected = [ true ];
    };
    testWireguardAllowsNftablesWithIptablesPackage = {
      expr = failedAssertions wireguardNftablesIptablesPackage;
      expected = [];
    };
    testWireguardAllowsNftablesWithIptablesExtraPackage = {
      expr = failedAssertions wireguardNftablesIptablesExtraPackage;
      expected = [];
    };
    testWireguardRejectsNftablesRuleset = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesRuleset);
      expected = [ true ];
    };
    testWireguardRejectsNftablesOldStateVersion = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesOldStateVersion);
      expected = [ true ];
    };
    testWireguardAllowsNftablesTables = {
      expr = failedAssertions wireguardNftablesTables;
      expected = [];
    };
    testWireguardRejectsNftablesIptablesTable = {
      expr = map (lib.hasInfix "`networking.nftables.tables` replaces ip filter")
        (failedAssertions wireguardNftablesIptablesTable);
      expected = [ true ];
    };
    testWireguardAllowsNftablesRulesetWithIptablesLegacy = {
      expr = failedAssertions wireguardNftablesIptablesLegacyRuleset;
      expected = [];
    };
    testWireguardAllowsNftablesIptablesTableWithIptablesLegacy = {
      expr = failedAssertions wireguardNftablesIptablesLegacyTable;
      expected = [];
    };
    testWireguardAllowsNftablesRulesetWithIptablesLegacyExtraPackage = {
      expr = failedAssertions wireguardNftablesIptablesLegacyExtraPackageRuleset;
      expected = [];
    };
    testWireguardRejectsNftablesRulesetWithIptablesBeforeLegacy = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesIptablesBeforeLegacyRuleset);
      expected = [ true ];
    };
    testWireguardRejectsNftablesRulesetWithRenamedIptables = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesRenamedIptablesRuleset);
      expected = [ true ];
    };
    testWireguardAllowsNftablesRulesetWithIptablesAfterLegacy = {
      expr = failedAssertions wireguardNftablesIptablesAfterLegacyRuleset;
      expected = [];
    };
    testWireguardRejectsNftablesRulesetWithRenamedIptablesExtraPackage = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesRenamedIptablesExtraPackageRuleset);
      expected = [ true ];
    };
    testWireguardRejectsNftablesRulesetWithCustomIptables = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesCustomIptablesRuleset);
      expected = [ true ];
    };
    testWireguardRejectsNftablesRulesetWithWrappedIptables = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesWrappedIptablesRuleset);
      expected = [ true ];
    };
    testWireguardRejectsNftablesRulesetWithForcedPath = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesIptablesForcedPathRuleset);
      expected = [ true ];
    };
    testWireguardEvaluatesWithNullPath = {
      expr = failedAssertions wireguardNullPath;
      expected = [];
    };
    testWireguardRejectsNftablesRulesetWithIptablesOnServicePath = {
      expr = map (lib.hasInfix "`networking.nftables.flushRuleset` deletes them")
        (failedAssertions wireguardNftablesIptablesOnServicePathRuleset);
      expected = [ true ];
    };
    testNetnsRESTAddresses = {
      expr = getRestAddresses netns;
      expected = with netns.nix-bitcoin.netns-isolation.netns; [ lnd.address clightning.address ];
    };
    testMempoolWaitsForSecrets = {
      expr = with mempool.systemd.services.mempool;
        map (lib.elem "nix-bitcoin-secrets.target") [ wants after ];
      expected = [ true true ];
    };
    testMempoolDefaultRpcPassword = { expr = failedAssertions mempool; expected = []; };
    testMempoolRejectsRpcPassword = {
      expr = map (lib.hasInfix "settings.CORE_RPC.PASSWORD` would be copied")
        (failedAssertions mempoolRpcPassword);
      expected = [ true ];
    };
    testMempoolRpcPasswordMigration = let
      password.CORE_RPC.PASSWORD = lib.mkForce "literal-password";
    in {
      expr = map (case: (builtins.tryEval (evaluate {
        nix-bitcoin.configVersion = case.version;
        services.mempool = { enable = true; inherit (case) settings; };
      }).system.stateVersion).success) [
        { version = "0.1.4"; settings = password; }
        { version = "0.1.4"; settings = {}; }
        { version = "0.1.5"; settings = password; }
        { version = null; settings = password; }
      ];
      expected = [ false true true true ];
    };
    testEmptySecretsMigration = {
      expr = map (case: (builtins.tryEval (evaluate {
        nix-bitcoin.configVersion = case.version;
        nix-bitcoin.setupSecrets = case.setupSecrets;
        services.lnd.enable = case.lnd;
      }).system.stateVersion).success) [
        { version = "0.1.5"; setupSecrets = true; lnd = false; }
        { version = "0.1.5"; setupSecrets = false; lnd = true; }
        { version = "0.1.5"; setupSecrets = false; lnd = false; }
        { version = "0.1.6"; setupSecrets = true; lnd = true; }
        { version = null; setupSecrets = true; lnd = true; }
      ];
      expected = [ false false true true true ];
    };
    testBackupsFollowPostgresqlCompression = let
      includes = compression: let
        list = builtins.readFile (backupsWithCompression compression).services.duplicity.includeFileList;
      in file: lib.hasInfix "/var/backup/postgresql/${file}\n" list;
    in {
      expr = {
        zstd = map (includes "zstd") [ "btcpaydb.sql.zstd" "nbxplorer.sql.zstd" "btcpaydb.sql.gz" ];
        none = map (includes "none") [ "btcpaydb.sql" "nbxplorer.sql" "btcpaydb.sql.gz" ];
      };
      expected = {
        zstd = [ true true false ];
        none = [ true true false ];
      };
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
      expected = { failed = []; alice = [ "clnrest" ]; };
    };
    # Offer the access hint only when the operator user exists
    testLnconnectAssertionHints = let
      hints = config: map (message: {
        grant = lib.hasInfix "extraGroups" message;
        defineUser = lib.hasInfix "define the user" message;
      }) (failedAssertions config);
    in {
      expr = {
        noUser = hints lnconnectNoOperator;
        existingUser = hints operatorAccountRoleDisabled;
        renamedAccount = map (lib.hasInfix "users.users.account.extraGroups")
          (failedAssertions operatorRenamedAccountRoleDisabled);
      };
      expected = {
        noUser = [ { grant = false; defineUser = true; } ];
        existingUser = [ { grant = true; defineUser = false; } ];
        renamedAccount = [ true ];
      };
    };
    # lndconnect reads the lnd user's copy, so only the clnrest access is checked
    testVersioningOperatorAccess = {
      expr = {
        clnrest = hasOperatorAccessNotice operatorAccountOnion;
        lndOnly = hasOperatorAccessNotice {
          imports = [ lndconnectOnion ];
          users.users.alice.isNormalUser = true;
          nix-bitcoin.operator.name = "alice";
        };
        explicitAccess = hasOperatorAccessNotice operatorAccountGrant;
        # An operator account from outside `users.users`, for example via LDAP
        externalOperator = hasOperatorAccessNotice {
          imports = [ lndconnectOnion ];
          nix-bitcoin.operator.name = "alice";
          services.clightning = {
            enable = true;
            port = 9736;
            plugins.clnrest = { enable = true; lnconnect = { enable = true; onion = true; }; };
          };
        };
      };
      expected = {
        clnrest = true; lndOnly = false; explicitAccess = false; externalOperator = true;
      };
    };
    testOnionAccessRejectsUnknownUser = {
      expr = map (lib.hasInfix "no-such-user") (failedAssertions onionAccessUnknownUser);
      expected = [ true ];
    };
    testOnionAccessAcceptsLoginName = {
      expr = failedAssertions onionAccessRenamedUser;
      expected = [ ];
    };
    testOnionAccessRejectsDisabledUser = {
      expr = map (lib.hasInfix "disabled-user") (failedAssertions onionAccessDisabledUser);
      expected = [ true ];
    };
    # Before 0.1.6, the access could name users that aren't defined or enabled in `users.users`
    testVersioningOnionAccessUndefinedUser = {
      expr = {
        undefined = hasAccessUsersNotice onionAccessExternalUser;
        current = passesVersionCheckAt "0.1.6" onionAccessExternalUser;
        currentFails = map (lib.hasInfix "external-user")
          (failedAssertions (evaluate {
            imports = [ onionAccessExternalUser ];
            nix-bitcoin.configVersion = "0.1.6";
          }));
        defined = hasAccessUsersNotice onionAccessLoginName;
        disabled = hasAccessUsersNotice {
          users.users.disabled-user = { isNormalUser = true; enable = false; };
          nix-bitcoin.onionAddresses.access."disabled-user" = [ "bitcoind" ];
        };
      };
      expected = {
        undefined = true; current = true; currentFails = [ true ]; defined = false; disabled = true;
      };
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
    testBtcpayserverJoinsClightningGroup = {
      expr = lib.elem "cln-rpc" btcpayserverCustomClightningGroup.users.users.btcpayserver.extraGroups;
      expected = true;
    };
    testReplicationWarnsWithoutHostKeyCheck = {
      expr = map (replication: builtins.length (replicationHostKeyWarnings replication)) [
        { sshfs.destination = "user@host:dir"; }
        { sshfs = { destination = "user@host:dir"; sshOptions = [ "StrictHostKeyChecking = No" ]; }; }
        { sshfs = { destination = "user@host:dir"; sshOptions = [ "reconnect,stricthostkeychecking=off" ]; }; }
        { local.directory = "/var/backup/cln"; sshfs.sshOptions = [ "StrictHostKeyChecking=no" ]; }
      ];
      expected = [ 0 1 1 0 ];
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

    # The replication SSH key is created when it's absent. An empty key, or a
    # symlink to a missing file, fails and is kept. A missing, empty or wrong
    # `.pub` is rebuilt from an unencrypted key.
    mkdir gen
    (
      cd gen
      key=clightning-replication-ssh-key
      fail() { echo "Replication SSH key: $*" >&2; exit 1; }
      ${replicationGenerator}
      [[ -z $(find . -name "$key.??????") ]] || fail "a temp file or dir was left behind"
      pub=$(< $key.pub)
      for breakPub in "rm $key.pub" ": > $key.pub" "echo ssh-ed25519 wrong > $key.pub"; do
        eval "$breakPub"
        ${replicationGenerator}
        [[ $(< $key.pub) == "$pub" ]] || fail "'$breakPub' wasn't repaired"
      done
      : > $key
      if ${replicationGenerator} 2> err; then fail "an empty key was accepted"; fi
      grep -q "Key file '$key' is empty" err || fail "unexpected error: $(< err)"
      [[ ! -s $key ]] || fail "an empty key was replaced"
      rm $key && ln -s missing $key
      if ${replicationGenerator} 2> /dev/null; then fail "a symlink to a missing key was accepted"; fi
      [[ -L $key ]] || fail "a symlink to a missing key was replaced"
      # Identities whose private key can't be read here keep their `.pub`: an
      # encrypted key, and a public key whose private key is in an SSH agent
      rm $key && ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -q -N secret -C "" -f $key
      publicKey=$(< $key.pub)
      for identity in encrypted public-only; do
        if [[ $identity == public-only ]]; then echo "$publicKey" > $key; fi
        echo kept > $key.pub
        ${replicationGenerator} || fail "the $identity identity failed"
        [[ $(< $key.pub) == kept ]] || fail "the .pub of the $identity identity was changed"
      done
    )

    echo '${toString (builtins.length (builtins.attrNames tests))} configuration tests passed' > "$out"
  ''
