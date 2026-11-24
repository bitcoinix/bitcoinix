{ lib, evaluate, failedAssertions }:
let
  mint = backend: onchain: module: evaluate {
    imports = [ module ];
    services.cdk-mintd = {
      enable = true;
      inherit backend;
      onchain.enable = onchain;
      url = "https://mint.example.org";
    };
  };
  disabled = evaluate {};
in lib.listToAttrs (lib.concatMap (backend: map (onchain: let
  config = mint backend onchain {};
  isolated = mint backend onchain { nix-bitcoin.netns-isolation.enable = true; };
  service = config.systemd.services.cdk-mintd;
in lib.nameValuePair "testCdkMintd-${backend}-${lib.boolToString onchain}" {
  expr = {
    assertions = failedAssertions config;
    lnd = config.services.lnd.enable;
    cln = config.services.clightning.enable;
    groups = config.users.users.cdk-mintd.extraGroups;
    seed = config.nix-bitcoin.secrets.cdk-mintd-seed.user;
    mnemonic = config.nix-bitcoin.secrets ? cdk-mintd-bdk-mnemonic;
    requires = service.requires;
    user = service.serviceConfig.User;
    hardened = service.serviceConfig.ProtectSystem;
    address = isolated.services.cdk-mintd.address;
    connections = isolated.nix-bitcoin.netns-isolation.services.cdk-mintd.connections;
  };
  expected = {
    assertions = [];
    lnd = backend == "lnd";
    cln = backend == "clightning";
    groups = lib.optional (backend == "clightning") "clightning"
      ++ lib.optional onchain "bitcoinrpc-public";
    seed = "cdk-mintd";
    mnemonic = onchain;
    requires = [ "${backend}.service" ] ++ lib.optional onchain "bitcoind.service";
    user = "cdk-mintd";
    hardened = "strict";
    address = "169.254.1.35";
    connections = [ "nginx" ] ++ lib.optional (backend == "lnd") "lnd"
      ++ lib.optional onchain "bitcoind";
  };
}) [ false true ]) [ "lnd" "clightning" ]) // {
  testCdkMintdDisabled = {
    expr = {
      unit = disabled.systemd.services ? cdk-mintd;
      seed = disabled.nix-bitcoin.secrets ? cdk-mintd-seed;
      lnd = disabled.services.lnd.enable;
      cln = disabled.services.clightning.enable;
    };
    expected = { unit = false; seed = false; lnd = false; cln = false; };
  };
  testCdkMintdCustomSecrets = {
    expr = let config = mint "lnd" true {
      services.cdk-mintd = {
        seedFile = "/secrets/custom-mint";
        onchain.mnemonicFile = "/secrets/custom-bdk";
      };
    }; in lib.filter (lib.hasPrefix "cdk-mintd") (lib.attrNames config.nix-bitcoin.secrets);
    expected = [];
  };
  testCdkMintdUnsupportedOnchain = {
    expr = map (module: lib.any (lib.hasInfix "cdk-mintd's BDK")
      (failedAssertions (mint "clightning" true module))) [
        { services.bitcoind.network = "testnet4"; }
        { services.bitcoind.prune = 1000; }
      ];
    expected = [ true true ];
  };
  testCdkMintdTor = {
    expr = let config = mint "lnd" false {
      imports = [ ../modules/presets/enable-tor.nix ];
      nix-bitcoin.onionServices.cdk-mintd.enable = true;
    }; in {
      enforce = config.services.cdk-mintd.tor.enforce;
      map = config.services.tor.relay.onionServices.cdk-mintd.map;
    };
    expected = {
      enforce = true;
      map = [{ port = 80; target = { addr = "127.0.0.1"; port = 8085; unix = null; }; }];
    };
  };
  testCdkMintdMacaroon = {
    expr = let config = mint "lnd" false {}; in
      builtins.fromJSON ("[" + config.services.lnd.macaroons.cdk-mintd.permissions + "]");
    expected = map (action: { entity = "uri"; inherit action; }) [
      "/lnrpc.Lightning/AddInvoice"
      "/lnrpc.Lightning/LookupInvoice"
      "/lnrpc.Lightning/SubscribeInvoices"
      "/lnrpc.Lightning/QueryRoutes"
      "/routerrpc.Router/SendPaymentV2"
      "/routerrpc.Router/SendToRouteV2"
      "/routerrpc.Router/TrackPaymentV2"
    ];
  };
}
