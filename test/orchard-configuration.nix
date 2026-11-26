{ lib, evaluate, failedAssertions }:
let
  orchard = module: evaluate {
    imports = [ module ];
    services.orchard.enable = true;
  };
  plain = orchard {};
  isolated = orchard { nix-bitcoin.netns-isolation.enable = true; };
  disabled = evaluate {};
in {
  testOrchardIntegration = {
    expr = let
      unit = plain.systemd.services.orchard;
      rpc = plain.services.cdk-mintd.settings.mint_management_rpc;
    in {
      assertions = failedAssertions plain;
      mintEnabled = plain.services.cdk-mintd.enable;
      rpc = builtins.removeAttrs rpc [ "tls_dir" ];
      bindsTo = unit.bindsTo;
      readWritePaths = unit.serviceConfig.ReadWritePaths;
      groups = unit.serviceConfig.SupplementaryGroups;
      environment = lib.getAttrs [ "SERVER_HOST" "SERVER_PORT" "MINT_RPC_MTLS" "MINT_DATABASE" ] unit.environment;
      caOwner = plain.nix-bitcoin.secrets.orchard-rpc-ca-key.user;
      serverOwner = plain.nix-bitcoin.secrets.orchard-rpc-server-key.user;
      clientOwner = plain.nix-bitcoin.secrets.orchard-rpc-client-key.user;
      restartHook = lib.any (lib.hasInfix "--job-mode=ignore-requirements orchard.service")
        plain.systemd.services.cdk-mintd.serviceConfig.ExecStartPost;
    };
    expected = {
      assertions = [];
      mintEnabled = true;
      rpc = { enabled = true; address = "127.0.0.1"; port = 8086; allow_insecure = false; allow_mint_quote_payment_override = false; };
      bindsTo = [ "cdk-mintd.service" ];
      readWritePaths = [ "/var/lib/orchard" ];
      groups = [ "orchard-mint" ];
      environment = {
        SERVER_HOST = "127.0.0.1";
        SERVER_PORT = "3321";
        MINT_RPC_MTLS = "true";
        MINT_DATABASE = "/var/lib/cdk-mintd/cdk-mintd.sqlite";
      };
      caOwner = "root";
      serverOwner = "cdk-mintd";
      clientOwner = "orchard";
      restartHook = true;
    };
  };
  testOrchardIsolation = {
    expr = {
      address = isolated.services.orchard.address;
      rpcAddress = isolated.services.cdk-mintd.settings.mint_management_rpc.address;
      connections = isolated.nix-bitcoin.netns-isolation.services.orchard.connections;
      api = isolated.systemd.services.orchard.environment.MINT_API;
    };
    expected = {
      address = "169.254.1.37";
      rpcAddress = "169.254.1.36";
      connections = [ "cdk-mintd" "nginx" ];
      api = "http://169.254.1.36:8085";
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
      secrets = lib.filter (lib.hasPrefix "orchard") (lib.attrNames disabled.nix-bitcoin.secrets);
      mint = disabled.services.cdk-mintd.enable;
    };
    expected = { unit = false; secrets = []; mint = false; };
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
      setupSecret = config.nix-bitcoin.secrets ? orchard-setup-key;
      client = config.nix-bitcoin.secrets.orchard-rpc-client-key.user;
      server = config.nix-bitcoin.secrets.orchard-rpc-server-key.user;
      database = config.systemd.services.orchard.environment.MINT_DATABASE;
    };
    expected = { assertions = []; setupSecret = false; client = "orchard"; server = "mint"; database = "/srv/mint/cdk-mintd.sqlite"; };
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
