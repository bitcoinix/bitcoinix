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
  versioningErrors = config: builtins.filter (message:
    lib.hasInfix "This version of nix-bitcoin contains" message
    || lib.hasInfix "is newer than the latest finalized release" message
  ) (failedAssertions config);
  releasedVersion = import ../version.nix;
  changes020Released = lib.versionAtLeast releasedVersion "0.2.0";

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

  # A host that only imports the modules
  modulesOnly = evaluate {};
  bitcoin = evaluate { services.bitcoind.enable = true; };
  regtest = evaluate { services.bitcoind = { enable = true; network = "regtest"; }; };
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
  torEnforced = evaluate {
    imports = [ ../modules/presets/enable-tor.nix ];
    services.electrs.enable = true;
  };
  torEnforcedNetns = evaluate {
    imports = [ ../modules/presets/enable-tor.nix ];
    services.electrs.enable = true;
    services.charge-lnd.enable = true;
    nix-bitcoin.netns-isolation = { enable = true; addressblock = 7; };
  };
  torEnforcedAvahi = evaluate {
    imports = [ ../modules/presets/enable-tor.nix ];
    services.electrs.enable = true;
    services.avahi.enable = true;
  };
  getNetworkRestriction = config: service: let
    serviceConfig = config.systemd.services.${service}.serviceConfig;
  in {
    allow = serviceConfig.IPAddressAllow;
    inaccessible = serviceConfig.InaccessiblePaths or [];
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
  trezor = { services.hardware-wallets.trezor = true; };
  trezorWithBridge = {
    imports = [ trezor ];
    services.hardware-wallets.trezorBridge = true;
  };
  # The rule lines of the Ledger and Trezor udev rules
  hardwareWalletRules = let
    config = evaluate { services.hardware-wallets = { ledger = true; trezor = true; }; };
    packages = builtins.filter (pkg: lib.elem pkg.name [ "ledger-udev-rules" "trezord-udev-rules" ])
      config.services.udev.packages;
  in map (pkg: builtins.filter (line: line != "" && !lib.hasPrefix "#" line)
    (lib.splitString "\n" pkg.text)) packages;
  # A system with udev and the Trezor Bridge, whose rules the build below checks
  hardwareWalletSystem = (pkgs.nixos {
    imports = [ nixBitcoinModule ];
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    system.stateVersion = "26.05";
    nix-bitcoin.secretsSetupMethod = "manual";
    services.hardware-wallets = { ledger = true; trezor = true; trezorBridge = true; };
  }).config;
  trezorBridge = module: let config = evaluate module; in {
    enable = config.services.trezord.enable;
    groups = config.systemd.services.trezord.serviceConfig.SupplementaryGroups or null;
    warnings = builtins.length
      (builtins.filter (lib.hasInfix "trezord can't open the Trezor") config.warnings);
  };
  btcpayserverCustomUser = evaluate {
    services.btcpayserver = { enable = true; user = "btcpay-custom"; group = "payments"; };
  };
  # The URL of the health check in the script of btcpayserver-admin
  btcpayserverAdminHealthUrl = rootpath: let
    script = (evaluate {
      services.btcpayserver = { enable = true; inherit rootpath; };
    }).systemd.services.btcpayserver-admin.script;
    line = lib.findFirst (lib.hasInfix "curl -fs -o /dev/null") "" (lib.splitString "\n" script);
  in lib.head (builtins.match ".*(http://[^' ;]*).*" line);
  lndMacaroon = name: macaroon: evaluate {
    services.lnd = { enable = true; macaroons.${name} = macaroon; };
  };
  lndMacaroonId = name: user: permissions:
    (lndMacaroon name { inherit user permissions; }).services.lnd.macaroons.${name}.rootKeyId;
  clightningReplication = replication: {
    services.clightning = { enable = true; replication = { enable = true; } // replication; };
  };
  replicationHostKeyWarnings = replication: builtins.filter
    (lib.hasInfix "disables SSH host key checking")
    (evaluate (clightningReplication replication)).warnings;
  replicationUnits = replication: (evaluate (clightningReplication replication)).systemd.services;
  replicationRequiredMounts = replication: let
    services = replicationUnits replication;
  in lib.genAttrs [ "clightning" "clightning-replication-mounts" ]
    (unit: services.${unit}.unitConfig.RequiresMountsFor or null);
  # A local replica directory, with disks declared at `mountPoints`
  replicationToLocalMounts = directory: mountPoints: {
    imports = [ (clightningReplication { local.directory = directory; }) ];
    fileSystems = lib.genAttrs mountPoints (_: { device = "/dev/disk/by-label/replica"; fsType = "ext4"; });
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
  # The same, with the account defined under an attribute that isn't its login name
  operatorRenamedAccountRoleDisabled = evaluate {
    imports = [ lndconnectOnion ];
    users.users.account = { name = "alice"; isNormalUser = true; };
    nix-bitcoin.operator.name = "alice";
    services.clightning = {
      inherit (operatorAccountOnion.services.clightning) enable port plugins;
    };
  };
  # The migration that docs/upgrading/0.1.6.md describes for a disabled role
  operatorAccountGrant = {
    imports = [ operatorAccountOnion ];
    nix-bitcoin.onionAddresses.access.alice = [ "clnrest" ];
    users.users.alice.extraGroups = [ "clightning" ];
  };
  operatorAccountExplicitAccess = evaluate operatorAccountGrant;
  # Whether a config written for the last release passes the versioning check
  passesVersionCheckAt = version: module: versioningErrors (evaluate {
    imports = [ module ];
    nix-bitcoin.configVersion = version;
  }) == [];
  hasNoticeAt = version: phrase: module: lib.any (lib.hasInfix phrase) (evaluate {
    imports = [ module ];
    nix-bitcoin.configVersion = version;
  }).nix-bitcoin.versioning.incompatibleChanges;
  # Check individual notices even when the unstable migration also applies.
  hasNotice = hasNoticeAt "0.1.5";
  hasOperatorAccessNotice = hasNotice "lnconnect-clnrest now gives the operator user";
  hasAccessUsersNotice = hasNotice "now accepts only users that are defined";
  hasReplicationMountNotice = hasNotice "clightning now requires the mounts for";
  hasWgConnectNotice = hasNotice "`nix-bitcoin-wg-connect` from the WireGuard preset now needs";
  hasRpcUsersNotice = hasNotice "now connect to bitcoind as their own RPC users";
  # The services that call RPC methods outside the public whitelist
  rpcUsersServices = {
    services.clightning.enable = true;
    services.mempool.enable = true;
    services.btcpayserver.enable = true;
  };
  rpcUsers = evaluate rpcUsersServices;
  hasSshPasswordNotice = hasNotice "so sshd accepts only keys";
  # The preset publishes sshd as an onion service
  secureNodeSsh = settings: {
    imports = [ ../modules/presets/secure-node.nix ];
    services.openssh = { enable = true; inherit settings; };
  };
  sshPasswordOptions = [ "PasswordAuthentication" "KbdInteractiveAuthentication" ];
  sshPasswordLogin = lib.genAttrs sshPasswordOptions (_: true);
  getSshPasswordLogin = module:
    lib.getAttrs sshPasswordOptions (evaluate module).services.openssh.settings;
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
      expr = map (case: passesVersionCheckAt case.version {
        services.clightning = {
          enable = true;
          plugins.${plugin}.enable = case.enable;
        };
      }) [
        { version = "0.1.4"; enable = true; }
        { version = "0.1.4"; enable = false; }
        { version = "0.1.5"; enable = true; }
        { version = "0.1.6"; enable = true; }
        { version = releasedVersion; enable = true; }
        { version = null; enable = true; }
      ];
      expected = [ false (!changes020Released) (!changes020Released) (!changes020Released) true true ];
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

  # The build check of RTL's address, run by the check below
  rtlAddressCheck = address: lib.head (builtins.filter (check: check.name == "check-rtl-address")
    (evaluate {
      services.rtl = { enable = true; nodes.lnd.enable = true; inherit address; };
    }).system.checks);
  # systemd would skip the listener or take a unix socket
  rtlAddressRefused = map (address: pkgs.testers.testBuildFailure' {
    drv = rtlAddressCheck address;
    expectedBuilderLogEntries = [ "must be a numeric IP address without a zone ID" "not '${address}'" ];
  }) [ "localhost" "fe80::1%lo" "/run/rtl/frontend.sock" "@rtl-ui" "1.2.3" ];
  rtlAddressAccepted = map rtlAddressCheck [ "127.0.0.1" "::1" "::ffff:127.0.0.1" "0.0.0.0" "::" ];

  lnurlConfig = backend: module: evaluate {
    imports = [ module ];
    services.unbeholden-lnurl = {
      enable = true;
      inherit backend;
      settings.addresses.test = {
        description = "Bitcoinix test";
        min_sendable = 1000;
        max_sendable = 1000000;
      };
    };
  };
  lnurlTests = lib.listToAttrs (lib.concatMap (backend: let
    config = lnurlConfig backend {};
    unit = config.systemd.services.unbeholden-lnurl;
  in [
    (lib.nameValuePair "testLnurl-${backend}-backend" {
      expr = {
        lnd = config.services.lnd.enable;
        cln = config.services.clightning.enable;
        assertions = failedAssertions config;
      };
      expected = { lnd = backend == "lnd"; cln = backend == "clightning"; assertions = []; };
    })
    (lib.nameValuePair "testLnurl-${backend}-unit" {
      expr = {
        user = unit.serviceConfig.User;
        startsWithBackend = builtins.elem "${backend}.service" unit.after;
        privateTmp = unit.serviceConfig.PrivateTmp;
        noNewPrivileges = unit.serviceConfig.NoNewPrivileges;
      };
      expected = {
        user = "unbeholden-lnurl";
        startsWithBackend = true;
        privateTmp = true;
        noNewPrivileges = true;
      };
    })
    (lib.nameValuePair "testLnurl-${backend}-secrets" {
      expr = map (name: config.nix-bitcoin.secrets.${name}.user)
        [ "unbeholden-lnurl-verify" "unbeholden-lnurl-withdraw" ];
      expected = [ "unbeholden-lnurl" "unbeholden-lnurl" ];
    })
    (lib.nameValuePair "testLnurl-${backend}-netns" {
      expr = let
        isolated = lnurlConfig backend { nix-bitcoin.netns-isolation.enable = true; };
      in {
        inherit (isolated.services.unbeholden-lnurl) address;
        inherit (isolated.nix-bitcoin.netns-isolation.services.unbeholden-lnurl) connections;
      };
      expected = {
        address = "169.254.1.34";
        connections = [ backend "nginx" ];
      };
    })
  ]) [ "lnd" "clightning" ]) // {
    testLnurlLndReceivePermissions = {
      expr = builtins.fromJSON ("["
        + (lnurlConfig "lnd" {}).services.lnd.macaroons.unbeholden-lnurl.permissions + "]");
      expected = map (action: { entity = "uri"; inherit action; }) [
        "/lnrpc.Lightning/AddInvoice"
        "/lnrpc.Lightning/LookupInvoice"
        "/lnrpc.Lightning/ListInvoices"
        "/lnrpc.Lightning/SubscribeInvoices"
      ];
    };
    testLnurlRevokesUnusedRune = {
      expr = lib.mapAttrs (_: config: lib.hasInfix "unbeholden-lnurl-rune"
        config.systemd.services.clightning.postStart) {
        cln = lnurlConfig "clightning" {};
        lnd = lnurlConfig "lnd" { services.clightning.enable = true; };
        disabled = evaluate { services.clightning.enable = true; };
      };
      expected = { cln = false; lnd = true; disabled = true; };
    };
    testLnurlTorProxy = {
      expr = let config = lnurlConfig "clightning" {
        imports = [ ../modules/presets/enable-tor.nix ];
      }; in {
        enforce = config.services.unbeholden-lnurl.tor.enforce;
        proxy = config.services.unbeholden-lnurl.settings.outbound_proxy;
      };
      expected = { enforce = true; proxy = "socks5://127.0.0.1:9050"; };
    };
    testLnurlRequiresFeature = {
      expr = builtins.elem "services.unbeholden-lnurl requires addresses, withdraw vouchers, notifications or nostr in its settings."
        (failedAssertions (evaluate { services.unbeholden-lnurl.enable = true; }));
      expected = true;
    };
    testLnurlInlineWithdrawSecret = {
      expr = let config = lnurlConfig "lnd" {
        services.unbeholden-lnurl.settings.withdraw_secret = "0123456789abcdef0123456789abcdef";
      }; in {
        file = config.services.unbeholden-lnurl.settings.withdraw_secret_file;
        secret = config.nix-bitcoin.secrets ? unbeholden-lnurl-withdraw;
      };
      expected = { file = null; secret = false; };
    };
    testLnurlDisabled = {
      expr = builtins.hasAttr "unbeholden-lnurl" modulesOnly.systemd.services;
      expected = false;
    };
    testLnurlRejectsNonPositiveAmounts = {
      expr = (builtins.tryEval (builtins.deepSeq
        (lnurlConfig "lnd" {
          services.unbeholden-lnurl.settings.addresses.test.min_sendable = lib.mkForce 0;
        }).services.unbeholden-lnurl.settings.addresses true)).success;
      expected = false;
    };
  };

  tests = lib.mapAttrs' (name: case: lib.nameValuePair "testREST-${name}" {
    expr = restAllowed case.args;
    inherit (case) expected;
  }) restCases // lnurlTests // extraConfigTests // pluginsConfigTests // pluginMigrationTests // {
    testLockedPackagesDefault = {
      expr = bitcoin.nix-bitcoin.useVersionLockedPkgs;
      expected = true;
    };
    testConfigVersionAssertion = {
      # Exercise both release states even after version.nix advances.
      expr = map (release: map (version: !(passesVersionCheckAt version {
        nix-bitcoin.versioning.releasedVersion = release;
      })) [ "0.1.6" "0.2.0" "0.2.1" null ]) [ "0.1.6" "0.2.0" ];
      expected = [ [ false true true false ] [ true false true false ] ];
    };
    testFutureConfigVersionMessage = {
      expr = let
        messages = versioningErrors (evaluate {
          nix-bitcoin = {
            configVersion = "0.2.0";
            versioning.releasedVersion = "0.1.6";
          };
        });
      in map (phrase: lib.any (lib.hasInfix phrase) messages) [
        ''nix-bitcoin.configVersion = "0.2.0" is newer than the latest finalized release (0.1.6).''
        ''Set nix-bitcoin.configVersion = "0.1.6" until the release is finalized.''
      ];
      expected = [ true true ];
    };
    testUnreleasedMigrationWarnings = {
      expr = map (release: map (version: let
        warnings = (evaluate {
          nix-bitcoin = {
            configVersion = version;
            versioning.releasedVersion = release;
          };
        }).warnings;
      in lib.all (phrase: lib.any (lib.hasInfix phrase) warnings) [
        "bitcoinix now uses only unstable nixpkgs"
        "checkReversePath from true"
        (if changes020Released then "See docs/upgrading/0.2.0.md." else "See docs/upgrading/0.2.0/.")
      ]) [ "0.1.6" "0.2.0" null ]) [ "0.1.6" "0.2.0" ];
      expected = [ [ true true false ] [ false false false ] ];
    };
    testReleasedMigrationError = {
      expr = map (release: let
        messages = versioningErrors (evaluate {
          nix-bitcoin = {
            configVersion = "0.1.5";
            versioning.releasedVersion = release;
            setupSecrets = true;
            secretsSetupMethod = lib.mkForce "setup-secrets";
          };
        });
      in {
        released = lib.any (message:
          lib.hasInfix "setup-secrets now fails" message && lib.hasInfix "See docs/upgrading/0.1.6.md." message
        ) messages;
        upcoming = lib.any (lib.hasInfix "bitcoinix now uses only unstable nixpkgs") messages;
        target = lib.any (lib.hasInfix ''set nix-bitcoin.configVersion = "${release}";'') messages;
      }) [ "0.1.6" "0.2.0" ];
      expected = [
        { released = true; upcoming = false; target = true; }
        { released = true; upcoming = true; target = true; }
      ];
    };
    testUnstableDefaultNotices = {
      expr = {
        reversePath = hasNotice "checkReversePath from true" {};
        strict = hasNotice "checkReversePath from true" {
          networking.firewall.checkReversePath = true;
        };
        noFirewall = hasNotice "checkReversePath from true" {
          networking.firewall.enable = false;
        };
        fuse = hasNotice "disables programs.fuse.enable" {};
        explicitFuse = hasNotice "disables programs.fuse.enable" {
          programs.fuse.enable = true;
        };
        replication = hasNotice "disables programs.fuse.enable" {
          services.clightning = {
            enable = true;
            replication = {
              enable = true;
              encrypt = true;
              local.directory = "/var/backup/clightning";
            };
          };
        };
      };
      expected = {
        reversePath = true; strict = false; noFirewall = false;
        fuse = true; explicitFuse = false; replication = false;
      };
    };
    testI2pSAM = {
      expr = let
        cfg = evaluate { services.bitcoind = { enable = true; i2p = true; }; };
      in cfg.services.i2pd.settings.sam;
      expected = { enabled = true; address = "127.0.0.1"; port = 7656; };
    };
    testI2pExposureDefaults = {
      expr = let
        cfg = evaluate { services.bitcoind = { enable = true; i2p = true; }; };
      in with cfg.services.i2pd.settings; [
        http.enabled httpproxy.enabled socksproxy.enabled ntcp2.published ssu2.published
      ];
      expected = [ false false false false false ];
    };
    testI2pExposureOverrides = {
      expr = let
        cfg = evaluate {
          services.bitcoind = { enable = true; i2p = true; };
          services.i2pd.settings = {
            http.enabled = true;
            httpproxy.enabled = true;
            socksproxy.enabled = true;
            ntcp2.published = true;
            ssu2.published = true;
          };
        };
      in with cfg.services.i2pd.settings; [
        http.enabled httpproxy.enabled socksproxy.enabled ntcp2.published ssu2.published
      ];
      expected = [ true true true true true ];
    };
    testI2pSAMNetns = {
      expr = let
        cfg = evaluate {
          services.bitcoind = { enable = true; i2p = true; };
          nix-bitcoin.netns-isolation.enable = true;
        };
      in {
        inherit (cfg.services.i2pd.settings.sam) enabled address port;
        inherit (cfg.services.i2pd) checkConfig;
        firewall = builtins.elem cfg.services.i2pd.settings.sam.port
          cfg.networking.firewall.interfaces.nb-br.allowedTCPPorts;
      };
      expected = { enabled = true; address = "169.254.1.10"; port = 7656; firewall = true; checkConfig = false; };
    };
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
    testNetworkRejectsUnsupportedValues = {
      expr = map (network: (builtins.tryEval
        (evaluate { services.bitcoind.network = network; }).services.bitcoind.network).success)
        [ "testnet" "signet" "" true ];
      expected = [ false false false false ];
    };
    testLegacyRegtestOption = {
      expr = map (value: let
        config = evaluate {
          services.bitcoind.regtest = value;
          nix-bitcoin.configVersion = releasedVersion;
        };
      in {
        inherit (config.services.bitcoind) network;
        warned = lib.any (lib.hasInfix "services.bitcoind.regtest") config.warnings;
      }) [ true false ];
      expected = [
        { network = "regtest"; warned = true; }
        { network = "mainnet"; warned = true; }
      ];
    };
    testConflictingNetworkOptions = {
      expr = (builtins.tryEval (evaluate {
        services.bitcoind = { regtest = true; network = "mainnet"; };
      }).services.bitcoind.network).success;
      expected = false;
    };
    testRemovedNetworkNameHelper = {
      expr = (builtins.tryEval (evaluate ({ config, ... }: {
        services.electrs.dataDir = "/var/lib/electrs/${config.services.bitcoind.makeNetworkName "bitcoin" "regtest"}";
      })).services.electrs.dataDir).success;
      expected = false;
    };
    testNetworkMigration = {
      expr = map (module: !(hasNotice
        "services.bitcoind.regtest has been replaced" module)) [
        { services.bitcoind.regtest = true; }
        { services.bitcoind.regtest = false; }
        { services.bitcoind.network = "regtest"; }
        {}
      ];
      expected = [ false false true true ];
    };
    testHistoricalNetworkMigrationPaths = {
      expr = map (case: let
        notices = (evaluate {
          services.bitcoind = case.settings;
          services.electrs.enable = true;
          nix-bitcoin.configVersion = "0.1.1";
        }).nix-bitcoin.versioning.incompatibleChanges;
      in {
        cookie = lib.any (lib.hasInfix
          "/var/lib/bitcoind/${case.cookiePath}") notices;
        index = lib.any (lib.hasInfix
          "rm -r /var/lib/electrs/${case.indexDir}") notices;
      }) [
        { settings = {}; cookiePath = ".cookie"; indexDir = "bitcoin"; }
        { settings.regtest = false; cookiePath = ".cookie"; indexDir = "bitcoin"; }
        { settings.regtest = true; cookiePath = "regtest/.cookie"; indexDir = "regtest"; }
        { settings.network = "mainnet"; cookiePath = ".cookie"; indexDir = "bitcoin"; }
        { settings.network = "regtest"; cookiePath = "regtest/.cookie"; indexDir = "regtest"; }
      ];
      expected = [
        { cookie = true; index = true; }
        { cookie = true; index = true; }
        { cookie = true; index = true; }
        { cookie = true; index = true; }
        { cookie = true; index = true; }
      ];
    };
    testNetworkNameOverrides = {
      expr = map (config: let
        inherit (config.nix-bitcoin.lib) networkName;
      in [
        (networkName {})
        (networkName { mainnet = "bitcoin"; })
        (networkName { mainnet = "Main"; regtest = "RegTest"; })
      ]) [ bitcoin regtest ];
      expected = [
        [ "mainnet" "bitcoin" "Main" ]
        [ "regtest" "regtest" "RegTest" ]
      ];
    };
    testNetworkServiceIntegration = {
      expr = map (network: let
        config = evaluate {
          services.bitcoind.network = network;
          services.clightning.enable = true;
          services.lnd.enable = true;
        };
      in {
        network = config.services.bitcoind.network;
        clnNetworkDir = config.services.clightning.networkDir;
        lndNetworkDir = config.services.lnd.networkDir;
      }) [ "mainnet" "regtest" ];
      expected = [
        {
          network = "mainnet";
          clnNetworkDir = "/var/lib/clightning/bitcoin";
          lndNetworkDir = "/var/lib/lnd/chain/bitcoin/mainnet";
        }
        {
          network = "regtest";
          clnNetworkDir = "/var/lib/clightning/regtest";
          lndNetworkDir = "/var/lib/lnd/chain/bitcoin/regtest";
        }
      ];
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
    testUnbeholdenWalletRejectsAllowedClientsWithNetns = {
      expr = map (lib.hasInfix "allowedClients` is not supported with netns-isolation")
        (failedAssertions (evaluate {
          services.unbeholden-wallet = { enable = true; allowedClients = [ "192.0.2.1" ]; };
          nix-bitcoin.netns-isolation.enable = true;
        }));
      expected = [ true ];
    };
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
    testChargeLndCredentialMigration = {
      expr = map (case: !(hasNoticeAt case.version "charge-lnd now receives explicit" {
        services.charge-lnd = { enable = case.enable; extraFlags = case.flags; };
      })) [
        { version = "0.1.6"; enable = true; flags = [ "--lnddir" "/custom/lnd" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir=/custom/lnd" ]; }
        { version = "0.1.6"; enable = false; flags = [ "--lnddir=/custom/lnd" ]; }
        { version = "0.1.6"; enable = true; flags = []; }
        { version = "0.1.6"; enable = true; flags = [ "--tlscert" "/custom/cert" "--macaroon" "/custom/macaroon" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir" "/custom/lnd" "--tlscert" "/custom/cert" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir=/custom/lnd" "--macaroon=/custom/macaroon" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir" "/custom/lnd" "--tlscert" "/custom/cert" "--macaroon" "/custom/macaroon" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir=/custom/lnd" "--tlscert=/custom/cert" "--macaroon=/custom/macaroon" ]; }
        { version = "0.1.6"; enable = true; flags = [ "--lnddir=/custom/lnd" "--tlscert" "/custom/cert" "--macaroon=/custom/macaroon" ]; }
        { version = releasedVersion; enable = true; flags = [ "--lnddir=/custom/lnd" ]; }
      ];
      expected = [ false false true true true false false true true true changes020Released ];
    };
    testMempoolNetworks = {
      expr = map (network: let
        config = evaluate {
          services.bitcoind.network = network;
          services.mempool.enable = true;
        };
      in {
        network = config.services.mempool.settings.MEMPOOL.NETWORK;
        rpcPort = config.services.mempool.settings.CORE_RPC.PORT;
        frontend = config.services.mempool.frontend.settings;
        usesPackagedFrontend = config.services.mempool.frontend.staticContentRoot.drvPath
          == config.nix-bitcoin.pkgs.mempool-frontend.drvPath;
      }) [ "mainnet" "regtest" ];
      expected = [
        {
          network = "mainnet";
          rpcPort = 8332;
          frontend = {};
          usesPackagedFrontend = true;
        }
        {
          network = "regtest";
          rpcPort = 18443;
          frontend = { MAINNET_ENABLED = false; REGTEST_ENABLED = true; ROOT_NETWORK = "regtest"; };
          usesPackagedFrontend = false;
        }
      ];
    };
    testMempoolFrontendOverrides = {
      expr = (evaluate {
        services.bitcoind.network = "regtest";
        services.mempool = {
          enable = true;
          frontend.settings = { MAINNET_ENABLED = true; ROOT_NETWORK = ""; };
        };
      }).services.mempool.frontend.settings;
      expected = { MAINNET_ENABLED = true; REGTEST_ENABLED = true; ROOT_NETWORK = ""; };
    };
    testMempoolNetworkMigration = {
      expr = map (case: !(hasNoticeAt case.version "Mempool now uses regtest" {
        services.bitcoind.network = case.network;
        services.mempool.enable = case.enable;
      })) [
        { version = "0.1.6"; network = "regtest"; enable = true; }
        { version = "0.1.6"; network = "mainnet"; enable = true; }
        { version = "0.1.6"; network = "regtest"; enable = false; }
        { version = releasedVersion; network = "regtest"; enable = true; }
      ];
      expected = [ false true true changes020Released ];
    };
    testLegacyMempoolNetworkMigration = {
      expr = map (case: let
        notices = (evaluate {
          nix-bitcoin.configVersion = "0.1.6";
          services.bitcoind.regtest = case.regtest;
          services.mempool.enable = case.enable;
        }).nix-bitcoin.versioning.incompatibleChanges;
      in {
        network = lib.any (lib.hasInfix "services.bitcoind.regtest has been replaced") notices;
        mempool = lib.any (lib.hasInfix "Mempool now uses regtest") notices;
      }) [
        { regtest = true; enable = true; }
        { regtest = false; enable = true; }
        { regtest = true; enable = false; }
      ];
      expected = [
        { network = true; mempool = true; }
        { network = true; mempool = false; }
        { network = true; mempool = false; }
      ];
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
      expr = map (case: passesVersionCheckAt case.version {
        services.mempool = { enable = true; inherit (case) settings; };
      }) [
        { version = "0.1.4"; settings = password; }
        { version = "0.1.4"; settings = {}; }
        { version = "0.1.5"; settings = password; }
        { version = "0.1.6"; settings = password; }
        { version = releasedVersion; settings = password; }
        { version = null; settings = password; }
      ];
      expected = [ false (!changes020Released) (!changes020Released) (!changes020Released) true true ];
    };
    # The 0.1.5 notices by their message. Once 0.2.0 is released, later notices block
    # every older config, so the version check tests above can't tell them apart.
    testMigrationNotices015 = let
      plugin = name: enable: { services.clightning = { enable = true; plugins.${name}.enable = enable; }; };
      mempool = settings: { services.mempool = { enable = true; inherit settings; }; };
      password.CORE_RPC.PASSWORD = lib.mkForce "literal-password";
      notice = phrase: module: map (version: hasNoticeAt version phrase module)
        [ "0.1.4" "0.1.5" releasedVersion ];
      currencyrate = "currencyrate plugin has been replaced";
      rebalance = "rebalance plugin now uses";
    in {
      expr = {
        currencyrate = notice currencyrate (plugin "currencyrate" true);
        currencyrateOff = notice currencyrate (plugin "currencyrate" false);
        rebalance = notice rebalance (plugin "rebalance" true);
        rebalanceOff = notice rebalance (plugin "rebalance" false);
        # The notice names the password file that mempool reads now
        mempool = notice "/bitcoin-rpcpassword-mempool`." (mempool password);
        mempoolOff = notice "CORE_RPC.PASSWORD` is no longer accepted" (mempool {});
      };
      expected = {
        currencyrate = [ true false false ]; currencyrateOff = [ false false false ];
        rebalance = [ true false false ]; rebalanceOff = [ false false false ];
        mempool = [ true false false ]; mempoolOff = [ false false false ];
      };
    };
    # Each method outside the public whitelist reaches only the user of the service
    # that calls it
    testRpcUsersWhitelists = {
      expr = lib.mapAttrs (_: user:
        map (method: lib.elem method user.rpcwhitelist) [ "getblockfrompeer" "gettxoutsetinfo" ]
      ) {
        inherit (rpcUsers.services.bitcoind.rpc.users) public clightning mempool btcpayserver;
        # trustedcoin replaces bcli, which calls `getblockfrompeer`
        trustedcoin = (evaluate {
          services.clightning = { enable = true; plugins.trustedcoin.enable = true; };
        }).services.bitcoind.rpc.users.clightning;
      };
      expected = {
        public = [ false false ];
        clightning = [ true false ];
        mempool = [ false true ];
        btcpayserver = [ true false ];
        trustedcoin = [ false false ];
      };
    };
    # An empty whitelist disables whitelisting, also for the clightning and mempool users
    testRpcUsersFollowEmptyPublicWhitelist = {
      expr = lib.mapAttrs (_: user: user.rpcwhitelist) {
        inherit ((evaluate {
          imports = [ rpcUsersServices ];
          services.bitcoind.rpc.users.public.rpcwhitelist = lib.mkForce [];
        }).services.bitcoind.rpc.users) public clightning mempool;
      };
      expected = { public = []; clightning = []; mempool = []; };
    };
    testRpcUsersConnect = {
      expr = with rpcUsers; {
        clightning = lib.hasInfix "/bitcoin-rpcpassword-clightning'" systemd.services.clightning.preStart;
        mempool = {
          user = services.mempool.settings.CORE_RPC.USERNAME;
          password = lib.hasInfix "/bitcoin-rpcpassword-mempool'" systemd.services.mempool.preStart;
        };
        # Neither service reads the password of `public`
        publicGroup = map (user: lib.elem "bitcoinrpc-public" users.users.${user}.extraGroups)
          [ "clightning" "mempool" ];
      };
      expected = {
        clightning = true;
        mempool = { user = "mempool"; password = true; };
        publicGroup = [ false false ];
      };
    };
    # Every config with one of the services gets the notice. Only generated secrets
    # need nothing else.
    testVersioningRpcUsers = {
      expr = {
        clightning = hasRpcUsersNotice { services.clightning.enable = true; };
        mempool = hasRpcUsersNotice { services.mempool.enable = true; };
        unaffected = hasRpcUsersNotice { services.electrs.enable = true; };
        nothingElse = map (generateSecrets: hasNotice "there's nothing else to do" {
          imports = [ rpcUsersServices ];
          nix-bitcoin = { inherit generateSecrets; };
        }) [ true false ];
        # The old config may have added both methods to a remote public user,
        # whatever the new one enables
        removesBoth = map (hasNotice "Remove `getblockfrompeer` and `gettxoutsetinfo` from") [
          { services.mempool.enable = true; }
          { services.clightning = { enable = true; plugins.trustedcoin.enable = true; }; }
        ];
        # A remote BTCPay user got `gettxoutsetinfo` through the public whitelist
        btcpayWhitelist = map (hasNotice "Set the whitelist of the BTCPay Server user") [
          rpcUsersServices
          { services.mempool.enable = true; }
        ];
        previous = hasNoticeAt "0.1.6" "now connect to bitcoind as their own RPC users"
          rpcUsersServices;
        # Once 0.2.0 is released, a config at 0.2.0 doesn't get the notice
        acknowledged = hasNoticeAt "0.2.0" "now connect to bitcoind as their own RPC users" {
          imports = [ rpcUsersServices ];
          nix-bitcoin.versioning.releasedVersion = "0.2.0";
        };
      };
      expected = {
        clightning = true; mempool = true; unaffected = false; nothingElse = [ true false ];
        removesBoth = [ true true ]; btcpayWhitelist = [ true false ]; previous = true;
        acknowledged = false;
      };
    };
    testEmptySecretsMigration = {
      expr = map (case: !(hasNoticeAt case.version "setup-secrets now fails" {
        nix-bitcoin.setupSecrets = case.setupSecrets;
        services.lnd.enable = case.lnd;
      })) [
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
    # duplicity applies the first matching entry, so these exclusions also win over `extraFiles`
    testBackupsExcludeChannelDatabasesFirst = let
      # The first block of the filelist, before `extraFiles`
      exclusions = module: lib.filter (line: line != "") (lib.splitString "\n" (lib.head
        (lib.splitString "\n\n" (builtins.readFile (evaluate {
          imports = [ module ];
          services.backups = { enable = true; extraFiles = [ "/var/lib" ]; };
        }).services.duplicity.includeFileList))));
      cln = "/var/lib/clightning/bitcoin";
      sqlite = db: [ "- ${db}" "- ${db}-*" ];
      lndGraph = "- /var/lib/lnd/graph";
    in {
      expr = {
        default = exclusions {};
        # Relative paths start in the network dir. Like Core Lightning, split at the
        # first `:` only, so the replica name ends with `:`.
        customWallet = exclusions {
          services.clightning.wallet = "sqlite3://./main.sqlite3:../replica//copy.sqlite3:";
        };
        # An empty path names no file
        emptyReplica = exclusions { services.clightning.wallet = "sqlite3://main.sqlite3:"; };
        emptyWallet = exclusions { services.clightning.wallet = "sqlite3://"; };
        # duplicity reads each line as a glob
        globWallet = exclusions { services.clightning.wallet = "sqlite3://channel[1].sqlite3"; };
        encryptedReplica = exclusions {
          services.clightning.replication = {
            enable = true;
            encrypt = true;
            local.directory = "/var/lib/clightning/replica/";
          };
        };
        sshfsReplica = exclusions {
          services.clightning.replication = {
            enable = true;
            encrypt = true;
            sshfs.destination = "user@host:dir";
          };
        };
        # duplicity fails on a selection outside its root
        backupRoot = exclusions {
          services.duplicity.root = "/var/lib";
          services.clightning.wallet = "sqlite3://${cln}/lightningd.sqlite3:/mnt/replica/lightningd.sqlite3";
        };
        # duplicity normalises its root
        backupRootDot = exclusions { services.duplicity.root = "/var/lib/."; };
      };
      expected = {
        default = sqlite "${cln}/lightningd.sqlite3" ++ [ lndGraph ];
        customWallet = sqlite "${cln}/lightningd.sqlite3" ++ sqlite "${cln}/main.sqlite3"
          ++ sqlite "/var/lib/clightning/replica/copy.sqlite3:" ++ [ lndGraph ];
        emptyReplica = sqlite "${cln}/lightningd.sqlite3" ++ sqlite "${cln}/main.sqlite3" ++ [ lndGraph ];
        emptyWallet = sqlite "${cln}/lightningd.sqlite3" ++ [ lndGraph ];
        globWallet = sqlite "${cln}/lightningd.sqlite3" ++ sqlite "${cln}/channel[[]1].sqlite3" ++ [ lndGraph ];
        encryptedReplica = sqlite "${cln}/lightningd.sqlite3"
          ++ sqlite "/var/cache/clightning-replication/plaintext/lightningd.sqlite3"
          ++ [ "- /var/lib/clightning/replica/lightningd-db" "- /var/cache/clightning-replication" lndGraph ];
        sshfsReplica = sqlite "${cln}/lightningd.sqlite3"
          ++ sqlite "/var/cache/clightning-replication/plaintext/lightningd.sqlite3"
          ++ [ "- /var/cache/clightning-replication" lndGraph ];
        backupRoot = sqlite "${cln}/lightningd.sqlite3" ++ [ lndGraph ];
        backupRootDot = sqlite "${cln}/lightningd.sqlite3" ++ [ lndGraph ];
      };
    };
    # The wallets of a remote bitcoind live on the other node
    testBackupsCopyLocalWallets = let
      copiesWallets = module: let
        config = evaluate {
          imports = [ module ];
          services.backups.enable = true;
          services.bitcoind.enable = true;
        };
      in {
        unit = (config.systemd.services.bitcoind-wallet-backup or { enable = false; }).enable;
        started = lib.hasInfix "bitcoind-wallet-backup.service" config.systemd.services.duplicity.preStart;
      };
    in {
      expr = {
        local = copiesWallets {};
        remote = copiesWallets ../modules/presets/bitcoind-remote.nix;
        noWallet = copiesWallets { services.bitcoind.disablewallet = true; };
      };
      expected = {
        local = { unit = true; started = true; };
        remote = { unit = false; started = false; };
        noWallet = { unit = false; started = false; };
      };
    };
    # Before 0.2.0, the backups included the Lightning channel databases and no
    # consistent wallet copies
    testVersioningBackupsContent = {
      expr = map (hasNotice "no longer includes the Lightning channel databases") [
        { services.backups.enable = true; }
        { services.lnd.enable = true; }
      ];
      expected = [ true false ];
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
    # A `mkForce` on `NODE_OPTIONS` must not drop RTL's preload unnoticed
    testRtlNodeOptions = let
      fails = env: lib.any (lib.hasInfix "NODE_OPTIONS` must contain")
        (failedAssertions (evaluate {
          services.rtl = { enable = true; nodes.lnd.enable = true; };
          systemd.services.rtl.environment = env;
        }));
    in {
      expr = {
        default = fails {};
        forced = fails { NODE_OPTIONS = lib.mkForce "--max-old-space-size=512"; };
      };
      expected = { default = false; forced = true; };
    };
    testRtlServerUrlOverride = let
      fails = extraConfig: lib.any (lib.hasInfix "Remove `Settings.lnServerUrl`")
        (failedAssertions (evaluate {
          services.rtl = { enable = true; nodes.lnd = { enable = true; inherit extraConfig; }; };
        }));
    in {
      expr = {
        default = fails {};
        other = fails { Settings.themeColor = "TEAL"; };
        override = fails { Settings.lnServerUrl = "http://127.0.0.1:18080"; };
        # RTL treats an empty `lnImplementation` as LND and sends the macaroon
        otherBackend = fails {
          lnImplementation = "";
          Settings.lnServerUrl = "https://127.0.0.1:3010";
        };
      };
      expected = { default = false; other = false; override = true; otherBackend = true; };
    };
    # A socket unit holds RTL's address and port, except with netns-isolation
    testRtlProxySocket = let
      rtl = module: evaluate {
        imports = [ module ];
        services.rtl = { enable = true; nodes.lnd.enable = true; };
      };
      sockets = module: lib.filterAttrs (name: _: lib.hasPrefix "rtl-proxy-" name)
        (rtl module).systemd.sockets;
      listen = module: lib.concatMap (socket: socket.listenStreams)
        (lib.attrValues (sockets module));
      unset = module: (rtl module).systemd.services.rtl.serviceConfig.UnsetEnvironment or null;
      portRejected = port: module: lib.any (lib.hasInfix "`services.rtl.port` must not be 0")
        (failedAssertions (rtl { imports = [ module ]; services.rtl.port = port; }));
      checked = module: lib.any (check: check.name == "check-rtl-address")
        (rtl module).system.checks;
      notice = hasNotice "systemd holds `services.rtl.address`";
      rtlOnly = { services.rtl = { enable = true; nodes.lnd.enable = true; }; };
    in {
      expr = {
        default = listen {};
        ipv6 = listen { services.rtl.address = "::1"; };
        # Like RTL's own listener before, whatever `net.ipv6.bindv6only` says
        dualStack = map (socket: socket.socketConfig.BindIPv6Only or null)
          (lib.attrValues (sockets { services.rtl.address = "::"; }));
        netns = listen { nix-bitcoin.netns-isolation.enable = true; };
        # A switch replaces the unit, as it doesn't restart a changed one
        renamed = lib.attrNames (sockets {}) != lib.attrNames (sockets { services.rtl.port = 3001; });
        # They would move RTL off its unix socket, also from an `EnvironmentFile`
        unset = unset {};
        unsetNetns = unset { nix-bitcoin.netns-isolation.enable = true; };
        # systemd can't listen on port 0. In its namespace, RTL takes 0 as 3000.
        portZero = portRejected 0 {};
        portOne = portRejected 1 {};
        portZeroNetns = portRejected 0 { nix-bitcoin.netns-isolation.enable = true; };
        # The system build checks the address, see `rtlAddressRefused`
        checked = checked {};
        checkedNetns = checked { nix-bitcoin.netns-isolation.enable = true; };
        notice = notice rtlOnly;
        # The notice doesn't name an address that systemd refuses
        noticeHostName = hasNotice "localhost:3000"
          { imports = [ rtlOnly ]; services.rtl.address = "localhost"; };
        noticeNetns = notice { imports = [ rtlOnly ]; nix-bitcoin.netns-isolation.enable = true; };
      };
      expected = {
        default = [ "127.0.0.1:3000" ];
        ipv6 = [ "[::1]:3000" ];
        dualStack = [ "both" ];
        netns = [];
        renamed = true;
        unset = [ "PORT" "HOST" ];
        unsetNetns = null;
        portZero = true;
        portOne = false;
        portZeroNetns = false;
        checked = true;
        checkedNetns = false;
        notice = true;
        noticeHostName = false;
        noticeNetns = false;
      };
    };
    # The socket unit has RTL's IP filter, which enforces Tor
    testRtlProxySocketIPFilter = let
      filters = enforce: let
        config = evaluate {
          services.rtl = { enable = true; nodes.lnd.enable = true; tor.enforce = enforce; };
        };
        socket = lib.head (lib.attrValues (lib.filterAttrs (name: _: lib.hasPrefix "rtl-proxy-" name)
          config.systemd.sockets));
        filter = unit: { allow = unit.IPAddressAllow or null; deny = unit.IPAddressDeny or null; };
      in {
        socket = filter socket.socketConfig;
        rtl = filter config.systemd.services.rtl.serviceConfig;
      };
      local = { allow = [ "127.0.0.1/32" "::1/128" ]; deny = "any"; };
      open = { allow = "any"; deny = "any"; };
    in {
      expr = { enforce = filters true; noEnforce = filters false; };
      expected = {
        enforce = { socket = local; rtl = local; };
        noEnforce = { socket = open; rtl = open; };
      };
    };
    # The proxy runs as RTL's user, which alone can reach RTL's socket. It has no
    # network of its own and can't see RTL's files, the secrets or the local resolvers.
    testRtlProxySandbox = let
      config = evaluate { services.rtl = { enable = true; nodes.lnd.enable = true; }; };
      proxy = config.systemd.services.rtl-proxy.serviceConfig;
    in {
      expr = {
        user = proxy.User or null;
        privateNetwork = proxy.PrivateNetwork or null;
        addressFamilies = proxy.RestrictAddressFamilies or null;
        # All masks fail closed, without a `-` prefix
        visible = lib.subtractLists (proxy.InaccessiblePaths or [])
          (config.nix-bitcoin.lib.localResolverPaths
           ++ [ config.services.rtl.dataDir config.nix-bitcoin.secretsDir ]);
      };
      expected = {
        user = "rtl";
        privateNetwork = true;
        addressFamilies = "AF_UNIX";
        visible = [];
      };
    };
    # Earlier versions copied the admin credentials of both backends to RTL.
    # RTL's start removes the copy of a backend that RTL doesn't use, as the rtl
    # user, who owns the macaroon dir also without lnd.
    testRtlUnusedCredentials = let
      removed = nodes: let
        config = evaluate { services.rtl = { enable = true; inherit nodes; }; };
        commands = config.systemd.services.rtl.serviceConfig.ExecStartPre;
      in map (copy: lib.any (command: lib.hasInfix "/bin/rm -f " command
                                      && lib.hasInfix "/var/lib/rtl/${copy}" command) commands)
        [ "macaroons/admin.macaroon" "clightning-admin-rune" ]
        ++ [ (lib.elem "d '/var/lib/rtl/macaroons' 0770 rtl rtl - -" config.systemd.tmpfiles.rules) ];
    in {
      expr = {
        both = removed { lnd.enable = true; clightning.enable = true; };
        lnd = removed { lnd.enable = true; };
        clightning = removed { clightning.enable = true; };
      };
      expected = {
        both = [ false false true ];
        lnd = [ false true true ];
        clightning = [ true false true ];
      };
    };
    # Before 0.2.0, RTL copied the admin credentials of its backends
    testVersioningRtlCredentials = let
      notices = nodes: map (phrase: hasNotice phrase { services.rtl = { enable = true; inherit nodes; }; })
        [ "RTL now gets its own lnd macaroon" "lnd restarts once" ];
    in {
      expr = {
        lnd = notices { lnd.enable = true; };
        clightning = notices { clightning.enable = true; };
        withoutRtl = hasNotice "RTL now gets its own lnd macaroon" { services.lnd.enable = true; };
        # Once 0.2.0 is released, a config at 0.2.0 doesn't get the notice
        acknowledged = hasNoticeAt "0.2.0" "RTL now gets its own lnd macaroon" {
          services.rtl = { enable = true; nodes.lnd.enable = true; };
          nix-bitcoin.versioning.releasedVersion = "0.2.0";
        };
      };
      expected = {
        lnd = [ true true ]; clightning = [ true false ]; withoutRtl = false; acknowledged = false;
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
    # Before 0.2.0, nix-bitcoin-wg-connect looked up the public IP when it got no host
    testVersioningWireguardConnectHost = {
      expr = {
        preset = hasWgConnectNotice wireguardLndconnect;
        noPreset = hasWgConnectNotice { services.lnd = { enable = true; lndconnect.enable = true; }; };
        before = hasNoticeAt "0.1.6" "`nix-bitcoin-wg-connect` from the WireGuard preset now needs"
          wireguardLndconnect;
        # Once 0.2.0 is released, a config at 0.2.0 doesn't get the notice
        acknowledged = hasNoticeAt "0.2.0" "`nix-bitcoin-wg-connect` from the WireGuard preset now needs" {
          imports = [ wireguardLndconnect ];
          nix-bitcoin.versioning.releasedVersion = "0.2.0";
        };
      };
      expected = { preset = true; noPreset = false; before = true; acknowledged = false; };
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
        current = passesVersionCheckAt releasedVersion onionAccessExternalUser;
        currentFails = map (lib.hasInfix "external-user")
          (failedAssertions (evaluate {
            imports = [ onionAccessExternalUser ];
            nix-bitcoin.configVersion = releasedVersion;
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
    testTorEnforceAllowsOnlyLocalhost = {
      expr = getNetworkRestriction torEnforced "electrs";
      expected = {
        allow = [ "127.0.0.1/32" "::1/128" ];
        inaccessible = [ "/run/nscd" "/run/systemd/resolve" "/run/dbus" ];
      };
    };
    testTorEnforceAllowsOnlyNetnsAddresses = {
      expr = map (getNetworkRestriction torEnforcedNetns) [ "electrs" "charge-lnd" ];
      expected = lib.replicate 2 {
        allow = [ "127.0.0.1/32" "::1/128" "169.254.7.0/24" ];
        inaccessible = [ "/run/nscd" "/run/systemd/resolve" "/run/dbus" ];
      };
    };
    testTorEnforceMasksAvahiWhenEnabled = {
      expr = (getNetworkRestriction torEnforcedAvahi "electrs").inaccessible;
      expected = [ "/run/nscd" "/run/systemd/resolve" "/run/dbus" "/run/avahi-daemon" ];
    };
    testNoTorEnforceKeepsNetwork = {
      expr = getNetworkRestriction bitcoin "bitcoind";
      expected = { allow = "any"; inaccessible = []; };
    };
    testResolverDirsCreated = {
      # The fail-closed masks have no `-` prefix, so each directory must exist or
      # the unit won't start; they're created independently of their resolver,
      # also without `tor.enforce`, for custom units with the restriction.
      expr = map (config: map (rule: builtins.elem rule config.systemd.tmpfiles.rules) [
        "d /run/nscd 0755 nscd nscd -"
        "d /run/systemd/resolve 0755 root root -"
        "d /run/dbus 0755 root root -"
      ]) [ torEnforced bitcoin modulesOnly ];
      expected = lib.replicate 3 [ true true true ];
    };
    testResolverDirCreatedForResolved = {
      # With resolved enabled the resolve dir is created under resolved's user
      expr = builtins.elem "d /run/systemd/resolve 0755 systemd-resolve systemd-resolve -"
        (evaluate {
          imports = [ ../modules/presets/enable-tor.nix ];
          services.electrs.enable = true;
          services.resolved.enable = true;
        }).systemd.tmpfiles.rules;
      expected = true;
    };
    testNscdKeepsRuntimeDirectory = {
      # Also without `tor.enforce`, for custom units with the restriction
      expr = map (config: config.systemd.services.nscd.serviceConfig.RuntimeDirectoryPreserve or null)
        [ torEnforced bitcoin modulesOnly ];
      expected = [ true true true ];
    };
    testNscdStalePidRemovedForGlibc = {
      # Only glibc's nscd keeps a pid file in the preserved directory
      expr = map (enableNsncd: lib.any (lib.hasInfix "rm -f /run/nscd/nscd.pid") (lib.toList
        ((evaluate { services.nscd.enableNsncd = enableNsncd; })
          .systemd.services.nscd.serviceConfig.ExecStartPre or [])))
        [ true false ];
      expected = [ false true ];
    };
    testNetnsRejectsMetadataAddressblock = {
      expr = map (block: builtins.any (lib.hasInfix "must not be 169 or 170") (failedAssertions (evaluate {
        services.bitcoind.enable = true;
        nix-bitcoin.netns-isolation = { enable = true; addressblock = block; };
      }))) [ 1 169 170 ];
      expected = [ false true true ];
    };
    testTorEnforceMigration = {
      expr = map (module: !(hasNotice "Services with `tor.enforce`" module)) [
        { services.bitcoind.enable = true; }
        { services.charge-lnd.enable = true; }
        { imports = [ ../modules/presets/enable-tor.nix ]; services.bitcoind.enable = true; }
        # Only nbxplorer enforces Tor. Its unit is created by btcpayserver.enable,
        # even when the internal nbxplorer.enable is false.
        {
          imports = [ ../modules/presets/enable-tor.nix ];
          services.bitcoind.tor.enforce = false;
          services.btcpayserver.enable = true;
          services.nbxplorer.enable = lib.mkForce false;
        }
      ];
      expected = [ true false false false ];
    };
    testSecureNodeSshKeysOnly = {
      expr = {
        preset = getSshPasswordLogin (secureNodeSsh {});
        explicit = getSshPasswordLogin (secureNodeSsh sshPasswordLogin);
        withoutPreset = getSshPasswordLogin { services.openssh.enable = true; };
      };
      expected = {
        preset = lib.genAttrs sshPasswordOptions (_: false);
        explicit = sshPasswordLogin;
        withoutPreset = sshPasswordLogin;
      };
    };
    # Before 0.2.0, the preset kept the NixOS defaults, which allow passwords
    testVersioningSecureNodeSshPasswords = {
      expr = {
        presetAndSshd = hasSshPasswordNotice (secureNodeSsh {});
        sshdDisabled = hasSshPasswordNotice {
          imports = [ (secureNodeSsh {}) ];
          services.openssh.enable = lib.mkForce false;
        };
        withoutPreset = hasSshPasswordNotice { services.openssh.enable = true; };
        # Once 0.2.0 is released, a config at 0.2.0 doesn't get the notice
        acknowledged = hasNoticeAt "0.2.0" "so sshd accepts only keys" {
          imports = [ (secureNodeSsh {}) ];
          nix-bitcoin.versioning.releasedVersion = "0.2.0";
        };
      };
      expected = { presetAndSshd = true; sshdDisabled = false; withoutPreset = false; acknowledged = false; };
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
    # setup-secrets fails for every secret when an owner doesn't exist
    testBtcpayserverAdminPasswordOwner = {
      expr = with btcpayserverCustomUser; {
        inherit (nix-bitcoin.secrets.btcpayserver-admin-password) user group;
        userExists = users.users ? btcpay-custom;
        groupExists = users.groups ? payments;
      };
      expected = { user = "btcpay-custom"; group = "payments"; userExists = true; groupExists = true; };
    };
    testBtcpayserverAdminRootpath = {
      expr = map btcpayserverAdminHealthUrl [ null "/" "btcpay" "/btcpay" "btcpay/" ];
      expected = [
        "http://127.0.0.1:23000/api/v1/health"
        "http://127.0.0.1:23000/api/v1/health"
        "http://127.0.0.1:23000/btcpay/api/v1/health"
        "http://127.0.0.1:23000/btcpay/api/v1/health"
        "http://127.0.0.1:23000/btcpay/api/v1/health"
      ];
    };
    # Before 0.2.0, group clightning could write the clightning data dir
    testVersioningClightningDataDir = {
      expr = map (hasNotice "Core Lightning data dir (`services.clightning.dataDir`) is no longer") [
        { services.clightning.enable = true; }
        { services.btcpayserver = { enable = true; lightningBackend = "clightning"; }; }
        { services.lnd.enable = true; }
      ];
      expected = [ true true false ];
    };
    # Before 0.2.0, bitcoind had a sysperms option, which Bitcoin Core ignores,
    # and dataDirReadableByGroup followed a blocks dir symlink
    testVersioningBitcoindGroupRead = {
      expr = {
        sysperms = map (hasNotice "`services.bitcoind.sysperms` has been removed") [
          { services.bitcoind.sysperms = true; }
          { services.bitcoind.enable = true; }
        ];
        removed = lib.any (lib.hasInfix "services.bitcoind.sysperms")
          (failedAssertions (evaluate { services.bitcoind.sysperms = false; }));
        symlink = map (hasNotice "of a blocks dir that is a symlink") [
          { services.bitcoind = { enable = true; dataDirReadableByGroup = true; }; }
          { services.bitcoind = { enable = true; dataDirReadableByGroup = true; network = "regtest"; }; }
          { services.bitcoind.enable = true; }
        ];
      };
      expected = { sysperms = [ true false ]; removed = true; symlink = [ true false false ]; };
    };
    testLndMacaroonRootKeyIds = let
      info = ''{"entity":"info","action":"read"}'';
      onchain = ''{"entity":"onchain","action":"read"}'';
      listUnspent = ''{"entity":"uri","action":"/walletrpc.WalletKit/ListUnspent"}'';
      id = lndMacaroonId "app" "app" "${info},${onchain}";
      idWithOptional = permissions: optionalPermissions: (lndMacaroon "app" {
        user = "app"; inherit permissions optionalPermissions;
      }).services.lnd.macaroons.app.rootKeyId;
    in {
      expr = {
        equivalent = map (permissions: lndMacaroonId "app" "app" permissions == id) [
          " ${onchain} ,\n${info}"
          "${info},${onchain},${info}"
          ''{"action":"read","entity":"info"},${onchain}''
        ] ++ [ (idWithOptional "${info},${onchain}" "" == id) ];
        changed = map (other: other != id) [
          (lndMacaroonId "app2" "app" "${info},${onchain}")
          (lndMacaroonId "app" "app2" "${info},${onchain}")
          (lndMacaroonId "app" "app" info)
          (lndMacaroonId "app" "app" ''${info},{"entity":"onchain","action":"write"}'')
          (idWithOptional "${info},${onchain}" listUnspent)
        ];
        # A permission that becomes optional gives a new ID too
        moved = idWithOptional "${info},${onchain}" listUnspent
          != idWithOptional "${info},${onchain},${listUnspent}" "";
        # The ID from before optional permissions, which deployed macaroons use
        unchanged = id == "7954054930408256540";
        # 0x6e62000000000000 to 0x6e62ffffffffffff
        inRange = builtins.stringLength id == 19
          && id >= "7953919891889717248" && id <= "7954201366866427903";
      };
      expected = {
        equivalent = [ true true true true ];
        changed = [ true true true true true ];
        moved = true;
        unchanged = true;
        inRange = true;
      };
    };
    testLndMacaroonRejectsInvalidPermissions = {
      expr = map (permissions:
        map (lib.hasInfix "services.lnd.macaroons.app.permissions must be")
          (failedAssertions (lndMacaroon "app" { user = "app"; inherit permissions; }))
      ) [
        ""
        ''"info:read"''
        ''{"entity":"info"}''
        ''{"entity":"info","action":1}''
        ''{"entity":"info","action":"read","caveat":"x"}''
        ''{"entity":"uri","action":"/a:b"}''
      ];
      expected = [ [ true ] [ true ] [ true ] [ true ] [ true ] [ true ] ];
    };
    # Only `uri` permissions can be optional
    testLndMacaroonRejectsInvalidOptionalPermissions = {
      expr = map (optionalPermissions:
        map (lib.hasInfix "services.lnd.macaroons.app.optionalPermissions must be")
          (failedAssertions (lndMacaroon "app" {
            user = "app";
            permissions = ''{"entity":"info","action":"read"}'';
            inherit optionalPermissions;
          }))
      ) [
        ""
        ''{"entity":"uri","action":"/walletrpc.WalletKit/ListUnspent"}''
        ''{"entity":"info","action":"read"}''
        ''"uri:/walletrpc.WalletKit/ListUnspent"''
        ''{"entity":"uri","action":"/a:b"}''
        ''{"entity":"uri","action":""}''
      ];
      expected = [ [] [] [ true ] [ true ] [ true ] [ true ] ];
    };
    testLndMacaroonRejectsUnsafeNames = let
      # `<name>.macaroon` must fit the 255 byte limit for file names
      nameOfLength = length: lib.concatStrings (lib.genList (_: "a") length);
    in {
      expr = map (name:
        map (lib.hasInfix "may only contain letters")
          (failedAssertions (lndMacaroon name { user = "app"; permissions = ''{"entity":"info","action":"read"}''; }))
      ) [ "../lnd/app" "a/b" ".app" "my app" "app.v2" (nameOfLength 246) (nameOfLength 247) ];
      expected = [ [ true ] [ true ] [ true ] [ true ] [] [] [ true ] ];
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
    # Each rule gives the device to the group and takes the `uaccess` tag away,
    # which would give it to the active local session too
    # The Ledger rules match every product of vendor 2c97 and the HW.1 IDs of
    # vendor 2581, as systemd's hwdb does
    testHardwareWalletRulesUseOnlyTheGroup = {
      expr = map (lines: {
        count = builtins.length lines;
        groupOnly = lib.all (line: lib.hasInfix ''GROUP="hardware-wallets"'' line
          && lib.hasInfix ''TAG-="uaccess"'' line && !lib.hasInfix ''TAG+="uaccess"'' line) lines;
        ledgerVendorWide = lib.any (line: lib.hasInfix ''"2c97"'' line && !lib.hasInfix "idProduct" line) lines;
        ledgerHw1 = lib.any (line: lib.hasInfix ''"2581"'' line && lib.hasInfix "1b7c|2b7c|3b7c|4b7c" line) lines;
      }) hardwareWalletRules;
      expected = [
        { count = 2; groupOnly = true; ledgerVendorWide = true; ledgerHw1 = true; }
        { count = 5; groupOnly = true; ledgerVendorWide = false; ledgerHw1 = false; }
      ];
    };
    testTrezorBridgeIsOptIn = let
      # The bridge enabled directly, which our rules keep from the device
      # unless trezord gets the group some other way
      trezord = module: { imports = [ trezor module ]; services.trezord.enable = true; };
      group = "hardware-wallets";
    in {
      expr = map trezorBridge [
        trezor
        trezorWithBridge
        { services.hardware-wallets.trezorBridge = true; }
        (trezord {})
        (trezord { users.users.trezord.extraGroups = [ group ]; })
        (trezord { users.groups.${group}.members = [ "trezord" ]; })
        (trezord { systemd.services.trezord.serviceConfig.Group = group; })
        (trezord { systemd.services.trezord.serviceConfig.SupplementaryGroups = group; })
        (trezord { systemd.services.trezord.serviceConfig.SupplementaryGroups = "audio ${group}"; })
        (trezord { services.hardware-wallets.group = "trezord"; })
        # The nixpkgs rules alone give the device to trezord
        { services.trezord.enable = true; }
      ];
      expected = [
        { enable = false; groups = null; warnings = 0; }
        { enable = true; groups = [ group ]; warnings = 0; }
        { enable = false; groups = null; warnings = 0; }
        { enable = true; groups = null; warnings = 1; }
        { enable = true; groups = null; warnings = 0; }
        { enable = true; groups = null; warnings = 0; }
        { enable = true; groups = null; warnings = 0; }
        { enable = true; groups = group; warnings = 0; }
        { enable = true; groups = "audio ${group}"; warnings = 0; }
        { enable = true; groups = null; warnings = 0; }
        { enable = true; groups = null; warnings = 0; }
      ];
    };
    testVersioningHardwareWalletAccess = {
      expr = map (module: map (phrase: hasNotice phrase module) [
        "are now available only to members of group"
        "The Trezor Bridge (trezord) no longer runs"
      ]) [
        trezor
        trezorWithBridge
        # The bridge enabled directly keeps running, and a warning covers it
        { imports = [ trezor ]; services.trezord.enable = true; }
        { services.hardware-wallets.ledger = true; }
        { services.trezord.enable = true; }
      ];
      expected = [ [ true true ] [ true false ] [ true false ] [ true false ] [ false false ] ];
    };
    # Without its disk, a local replica would land on the disk below the mount point
    testReplicationRequiresLocalMounts = {
      expr = map replicationRequiredMounts [
        { local.directory = "/mnt/replica"; }
        { local.directory = "/mnt/replica"; encrypt = true; }
        { sshfs.destination = "user@host:dir"; encrypt = true; }
      ];
      expected = [
        { clightning = [ ''"/mnt/replica"'' ]; clightning-replication-mounts = null; }
        { clightning = [ ''"/mnt/replica"'' ]; clightning-replication-mounts = [ ''"/mnt/replica"'' ]; }
        { clightning = null; clightning-replication-mounts = null; }
      ];
    };
    # systemd splits these paths at whitespace and expands `%` specifiers
    testReplicationQuotesLocalDirectory = let
      clightning = (replicationUnits { local.directory = ''/mnt/backup disk/"a" \b %c''; }).clightning;
      quoted = ''"/mnt/backup disk/\"a\" \\b %%c"'';
    in {
      expr = {
        requiresMountsFor = clightning.unitConfig.RequiresMountsFor;
        readWritePaths = lib.elem quoted clightning.serviceConfig.ReadWritePaths;
      };
      expected = { requiresMountsFor = [ quoted ]; readWritePaths = true; };
    };
    # Before 0.2.0, clightning started without the mount of its local replica
    testVersioningReplicationLocalMounts = let
      onDisk = replicationToLocalMounts "/mnt/replica" [ "/mnt/replica" ];
    in {
      expr = {
        onDisk = hasReplicationMountNotice onDisk;
        onRoot = hasReplicationMountNotice (replicationToLocalMounts "/var/backup/clightning" [ ]);
        sshfs = hasReplicationMountNotice (clightningReplication { sshfs.destination = "user@host:dir"; });
        previous = hasNoticeAt "0.1.6" "clightning now requires the mounts for" onDisk;
        # Once 0.2.0 is released, a config at 0.2.0 doesn't get the notice
        acknowledged = hasNoticeAt "0.2.0" "clightning now requires the mounts for" {
          imports = [ onDisk ];
          nix-bitcoin.versioning.releasedVersion = "0.2.0";
        };
      };
      expected = { onDisk = true; onRoot = true; sshfs = false; previous = true; acknowledged = false; };
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

    # udevd sorts its rule files by name. On NixOS it reads them from
    # /etc/udev/rules.d, which also holds copies of systemd's own rules. The
    # hardware wallet rules must run after the nixpkgs Trezor rules and systemd's
    # uaccess rules, and before the rules that apply the uaccess tag.
    (
      rules=${hardwareWalletSystem.environment.etc."udev/rules.d".source}
      systemd=${hardwareWalletSystem.systemd.package}
      fail() { echo "Hardware wallet udev rules: $*" >&2; exit 1; }
      order=$(ls "$rules" | LC_ALL=C sort \
        | grep -E '^(51-trezor|70-uaccess|71-hardware-wallets-[a-z]+|73-seat-late)\.rules$' | tr '\n' ' ')
      expected="51-trezor.rules 70-uaccess.rules 71-hardware-wallets-ledger.rules 71-hardware-wallets-trezor.rules 73-seat-late.rules "
      [[ $order == "$expected" ]] || fail "unexpected order: $order"
      grep -qF 'ENV{ID_HARDWARE_WALLET}=="1", TAG+="uaccess"' "$rules/70-uaccess.rules" \
        || fail "70-uaccess.rules no longer tags hardware wallets, recheck our rules"
      grep -qF 'TAG=="uaccess' "$rules/73-seat-late.rules" \
        || fail "73-seat-late.rules no longer applies the uaccess tag, recheck our rules"
      $systemd/bin/udevadm verify --resolve-names=never "$rules"/71-hardware-wallets-*.rules \
        || fail "udevadm verify failed"
    )

    # RTL's address check fails for an address that systemd can't hold a port on,
    # and passes for a numeric IP address
    (
      for result in ${toString (rtlAddressRefused ++ rtlAddressAccepted)}; do [[ -e $result ]]; done
    )

    echo '${toString (builtins.length (builtins.attrNames tests))} configuration tests passed' > "$out"
  ''
