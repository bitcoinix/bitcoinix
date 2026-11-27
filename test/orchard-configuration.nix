{ lib, evaluate, failedAssertions }:
let
  orchard = module: evaluate {
    imports = [ module ];
    services.orchard.enable = true;
  };
  plain = orchard {};
  isolated = orchard { nix-bitcoin.netns-isolation.enable = true; };
  disabled = evaluate {};
  proxySockets = config: lib.filterAttrs (name: _: lib.hasPrefix "orchard-proxy-" name) config.systemd.sockets;
in {
  testOrchardIntegration = {
    expr = let
      unit = plain.systemd.services.orchard;
      tlsUnit = plain.systemd.services.orchard-rpc-tls;
      mintUnit = plain.systemd.services.cdk-mintd;
      rpc = plain.services.cdk-mintd.settings.mint_management_rpc;
    in {
      assertions = failedAssertions plain;
      mintEnabled = plain.services.cdk-mintd.enable;
      inherit rpc;
      bindsTo = unit.bindsTo;
      orchardRequiresTls = builtins.elem "orchard-rpc-tls.service" unit.requires;
      mintRequiresTls = builtins.elem "orchard-rpc-tls.service" mintUnit.requires;
      tlsPrivateNetwork = tlsUnit.serviceConfig.PrivateNetwork;
      syslogIdentifier = unit.serviceConfig.SyslogIdentifier;
      readWritePaths = unit.serviceConfig.ReadWritePaths;
      groups = unit.serviceConfig.SupplementaryGroups;
      environment = lib.getAttrs [ "SERVER_SOCKET" "MINT_RPC_MTLS" "MINT_DATABASE" "MINT_RPC_CA" ] unit.environment;
      secrets = lib.filter (lib.hasPrefix "orchard") (lib.attrNames plain.nix-bitcoin.secrets);
      setupKeyOwner = plain.nix-bitcoin.secrets.orchard-setup-key.user;
      restartHook = lib.any (lib.hasInfix "--job-mode=ignore-requirements orchard.service")
        mintUnit.serviceConfig.ExecStartPost;
      orchardGrantsAccess = lib.any (lib.hasInfix "orchard-database-access") unit.serviceConfig.ExecStartPre;
      mintGrantsAccess = lib.any (lib.hasInfix "orchard-database-access") mintUnit.serviceConfig.ExecStartPost;
    };
    expected = {
      assertions = [];
      mintEnabled = true;
      rpc = {
        enabled = true;
        address = "127.0.0.1";
        port = 8086;
        tls_dir = "/run/orchard-rpc-tls/server";
        allow_insecure = false;
        allow_mint_quote_payment_override = false;
      };
      bindsTo = [ "cdk-mintd.service" ];
      orchardRequiresTls = true;
      mintRequiresTls = true;
      tlsPrivateNetwork = true;
      syslogIdentifier = "orchard";
      readWritePaths = [ "/var/lib/orchard" ];
      groups = [ "orchard-mint" ];
      environment = {
        SERVER_SOCKET = "/run/orchard/orchard.sock";
        MINT_RPC_MTLS = "true";
        MINT_DATABASE = "/var/lib/cdk-mintd/cdk-mintd.sqlite";
        MINT_RPC_CA = "/run/orchard-rpc-tls/client/ca.pem";
      };
      secrets = [ "orchard-setup-key" ];
      setupKeyOwner = "orchard";
      restartHook = true;
      orchardGrantsAccess = true;
      mintGrantsAccess = false;
    };
  };
  testOrchardIsolation = {
    expr = {
      address = isolated.services.orchard.address;
      rpcAddress = isolated.services.cdk-mintd.settings.mint_management_rpc.address;
      connections = isolated.nix-bitcoin.netns-isolation.services.orchard.connections;
      api = isolated.systemd.services.orchard.environment.MINT_API;
      listener = lib.filterAttrs (name: _: lib.hasPrefix "SERVER_" name) isolated.systemd.services.orchard.environment;
      sockets = lib.attrNames (proxySockets isolated);
    };
    expected = {
      address = "169.254.1.37";
      rpcAddress = "169.254.1.36";
      connections = [ "cdk-mintd" "nginx" ];
      api = "http://169.254.1.36:8085";
      listener = { SERVER_HOST = "169.254.1.37"; SERVER_PORT = "3321"; };
      sockets = [];
    };
  };
  testOrchardMintAddress = {
    expr = map (address: (orchard { services.cdk-mintd.address = address; })
      .systemd.services.orchard.environment.MINT_API) [ "::" "[::]" "::1" "0.0.0.0" ];
    expected = [ "http://[::1]:8085" "http://[::1]:8085" "http://[::1]:8085" "http://127.0.0.1:8085" ];
  };
  testOrchardDisabled = {
    expr = {
      unit = disabled.systemd.services ? orchard;
      tlsUnit = disabled.systemd.services ? orchard-rpc-tls;
      secrets = lib.filter (lib.hasPrefix "orchard") (lib.attrNames disabled.nix-bitcoin.secrets);
      mint = disabled.services.cdk-mintd.enable;
      sockets = lib.attrNames (proxySockets disabled);
    };
    expected = { unit = false; tlsUnit = false; secrets = []; mint = false; sockets = []; };
  };
  testOrchardProxy = {
    expr = let
      unit = plain.systemd.services.orchard.serviceConfig;
      proxy = plain.systemd.services.orchard-proxy.serviceConfig;
    in {
      listeners = lib.concatMap (socket: socket.listenStreams) (lib.attrValues (proxySockets plain));
      runtimeDirectory = unit.RuntimeDirectory;
      runtimeMode = unit.RuntimeDirectoryMode;
      proxyUser = proxy.User;
      proxyPrivateNetwork = proxy.PrivateNetwork;
      proxyMasksData = builtins.elem plain.services.orchard.dataDir proxy.InaccessiblePaths;
    };
    expected = {
      listeners = [ "127.0.0.1:3321" ];
      runtimeDirectory = "orchard";
      runtimeMode = "0700";
      proxyUser = "orchard";
      proxyPrivateNetwork = true;
      proxyMasksData = true;
    };
  };
  testOrchardCustom = {
    expr = let config = orchard {
      services.orchard = {
        setupKeyFile = "/run/keys/orchard";
        user = "orchard";
        group = "orchard-web";
        dataDir = "/srv/orchard";
      };
      services.cdk-mintd = { user = "mint"; group = "mint-group"; dataDir = "/srv/mint"; };
    }; in {
      assertions = failedAssertions config;
      secrets = lib.filter (lib.hasPrefix "orchard") (lib.attrNames config.nix-bitcoin.secrets);
      database = config.systemd.services.orchard.environment.MINT_DATABASE;
    };
    expected = { assertions = []; secrets = []; database = "/srv/mint/cdk-mintd.sqlite"; };
  };
  testOrchardTor = {
    expr = let config = orchard {
      imports = [ ../modules/presets/enable-tor.nix ];
      nix-bitcoin.onionServices.orchard.enable = true;
    }; in {
      enforce = config.services.orchard.tor.enforce;
      allow = config.systemd.services.orchard.serviceConfig.IPAddressAllow;
      port = (lib.head config.services.tor.relay.onionServices.orchard.map).port;
    };
    expected = { enforce = true; allow = [ "127.0.0.1/32" "::1/128" ]; port = 80; };
  };
  testOrchardInvalidOptions = {
    expr = map (module: failedAssertions (orchard module) != []) [
      { services.orchard.setupKeyFile = "relative"; }
      { services.orchard.user = "cdk-mintd"; }
      { services.orchard.mintRpcPort = 0; }
      { services.orchard.group = "cdk-mintd"; }
      { services.orchard.dataDir = "/var/lib/cdk-mintd/web"; }
      { services.orchard.dataDir = "/var/lib"; }
    ];
    expected = [ true true true true true true ];
  };
}
