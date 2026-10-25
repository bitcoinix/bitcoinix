{ lib, ... }:

with lib;
let
  mkRenamedAnnounceTorOption = service:
    # use mkRemovedOptionModule because mkRenamedOptionModule fails with an infinite recursion error
    mkRemovedOptionModule [ "services" service "announce-tor" ] ''
      Use option `nix-bitcoin.onionServices.${service}.public` instead.
    '';

  mkSplitEnforceTorOption = service:
    (mkRemovedOptionModule [ "services" service "enforceTor" ] ''
      The option has been split into options `tor.proxy` and `tor.enforce`.
      Set `tor.proxy = true` to proxy outgoing connections with Tor.
      Set `tor.enforce = true` to only allow connections (incoming and outgoing) through Tor.
    '');
  mkRenamedEnforceTorOption = service:
    (mkRenamedOptionModule [ "services" service "enforceTor" ] [ "services" service "tor" "enforce" ]);

in {
  imports = [
    (mkRenamedOptionModule [ "services" "bitcoind" "bind" ] [ "services" "bitcoind" "address" ])
    (mkRenamedOptionModule [ "services" "bitcoind" "rpcallowip" ] [ "services" "bitcoind" "rpc" "allowip" ])
    (mkRenamedOptionModule [ "services" "bitcoind" "rpcthreads" ] [ "services" "bitcoind" "rpc" "threads" ])
    (mkRenamedOptionModule [ "services" "clightning" "bind-addr" ] [ "services" "clightning" "address" ])
    (mkRenamedOptionModule [ "services" "clightning" "bindport" ] [ "services" "clightning" "port" ])
    (mkRenamedOptionModule [ "services" "lnd" "rpclisten" ] [ "services" "lnd" "rpcAddress" ])
    (mkRenamedOptionModule [ "services" "lnd" "listen" ] [ "services" "lnd" "address" ])
    (mkRenamedOptionModule [ "services" "lnd" "listenPort" ] [ "services" "lnd" "port" ])
    (mkRenamedOptionModule [ "services" "btcpayserver" "bind" ] [ "services" "btcpayserver" "address" ])
    (mkRenamedOptionModule [ "nix-bitcoin" "setup-secrets" ] [ "nix-bitcoin" "setupSecrets" ])

    (mkRenamedAnnounceTorOption "clightning")
    (mkRenamedAnnounceTorOption "lnd")

    # 0.0.53
    (mkRemovedOptionModule [ "services" "electrs" "high-memory" ] ''
      This option is no longer supported by electrs 0.9.0. Electrs now always uses
      bitcoin peer connections for syncing blocks. This performs well on low and high
      memory systems.
    '')
    # 0.0.86
    (mkRemovedOptionModule [ "services" "lnd" "restOnionService" "enable" ] ''
      Set the following options instead:
      services.lnd.lndconnect = {
        enable = true;
        onion = true;
      }
    '')
    (mkRemovedOptionModule [ "services" "lnd" "lndconnectOnion" ] ''
      Set the following options instead:
      services.lnd.lndconnect = {
        enable = true;
        onion = true;
      }
    '')
  ] ++
  # 0.0.59
  (map mkSplitEnforceTorOption [
    "clightning"
    "lnd"
    "bitcoind"
  ]) ++
  (map mkRenamedEnforceTorOption [
    "btcpayserver"
    "rtl"
    "electrs"
  ]) ++
  # 0.0.77
  [
    (mkRemovedOptionModule [ "services" "clightning" "plugins" "commando" ] ''
      clightning 0.12.0 ships with a reimplementation of the commando plugin
      that is incompatible with the commando module that existed in
      nix-bitcoin. The new built-in commando plugin is always enabled. For
      information on how to use it, run `lightning-cli help commando` and
      `lightning-cli help commando-rune`.
    '')
  ] ++
  # 0.0.92
  [
    (mkRemovedOptionModule [ "services" "spark-wallet" ] ''
      Spark Lightning Wallet is unmaintained and incompatible with clightning
      23.05. Therefore, the spark-wallet module has been removed from
      nix-bitcoin. For a replacement, consider using the rtl (Ride The
      Lightning) module or the clnrest plugin in combination with the
      Zeus mobile wallet.
    '')
  ]
  ++
  # 0.0.98
  [
    (mkRemovedOptionModule [ "services" "clightning" "plugins" "clboss" "acknowledgeDeprecation" ] ''
      `clboss` is maintained again and has been un-deprecated.
    '')
  ]
  ++
  # 0.0.106
  (map (plugin:
    mkRemovedOptionModule [ "services" "clightning" "plugins" plugin ] ''
      This plugin is no longer maintained.
    '')
    [ "summary" "helpme" "prometheus" ]
  )
  ++
  # 0.1.0
  [
    (mkRemovedOptionModule [ "services" "joinmarket" ] ''
      The joinmarket project is no longer maintained. The upstream project is
      archived:
      https://github.com/JoinMarket-Org/joinmarket-clientserver/releases/tag/v0.9.12
    '')
    (mkRemovedOptionModule [ "services" "joinmarket-ob-watcher" ] ''
      The joinmarket-ob-watcher is no longer maintained.
    '')
  ]
  ++
  # 0.1.1
  [
    (mkRemovedOptionModule [ "services" "liquidd" ] ''
      Liquid support has been removed from bitcoinix. Remove services.liquidd and any
      Liquid-specific onion service or network namespace settings from your configuration.
      Your Liquid wallets are not deleted; see docs/upgrading.md,
      "Upgrading to config version 0.1.1".
    '')
    (mkRemovedOptionModule [ "services" "btcpayserver" "lbtc" ] ''
      Liquid support has been removed from bitcoinix. Remove services.btcpayserver.lbtc
      from your configuration. BTCPay Server now supports Bitcoin and Lightning only.
    '')
    (mkRemovedOptionModule [ "nix-bitcoin" "netns-isolation" "allowedUser" ] ''
      The netns-exec wrapper has been removed, so there is no user to authorize.
      Remove nix-bitcoin.netns-isolation.allowedUser from your configuration.
      To run a command in a service namespace, use `sudo ip netns exec nb-<service> <command>`.
    '')
    (mkRemovedOptionModule [ "services" "lightning-pool" ] ''
      Lightning Pool support has been removed from bitcoinix to reduce maintenance scope.
      Remove services.lightning-pool and any Pool-specific onion service or network
      namespace settings from your configuration. Manage Pool separately if needed;
      see docs/upgrading.md, "Upgrading to config version 0.1.1".
    '')
    (mkRemovedOptionModule [ "services" "lightning-loop" ] ''
      Lightning Loop support has been removed from bitcoinix to reduce maintenance scope.
      Remove services.lightning-loop and any Loop-specific onion service or network
      namespace settings from your configuration. Manage Loop separately if needed;
      see docs/upgrading.md, "Upgrading to config version 0.1.1".
    '')
    (mkRemovedOptionModule [ "services" "rtl" "nodes" "lnd" "loop" ] ''
      RTL's Lightning Loop integration has been removed along with Lightning Loop support.
      Remove services.rtl.nodes.lnd.loop from your configuration.
    '')
    (mkRemovedOptionModule [ "services" "clightning-rest" ] ''
      c-lightning-REST is no longer maintained and has been removed from bitcoinix.
      Remove services.clightning-rest and enable services.clightning.plugins.clnrest instead.
      See docs/upgrading.md, "Upgrading to config version 0.1.1", for migration steps.
    '')
    (mkRemovedOptionModule [ "services" "rtl" "cl-rest" ] ''
      c-lightning-REST is no longer maintained and has been removed from bitcoinix.
      Remove services.rtl.cl-rest. RTL uses services.clightning.plugins.clnrest instead.
      See docs/upgrading.md, "Upgrading to config version 0.1.1", for migration steps.
    '')
  ]
  ++
  # 0.1.3
  [
    (mkRemovedOptionModule [ "services" "bitcoind" "package" ] ''
      Bitcoin Knots support and bitcoind package selection have been removed from bitcoinix.
      Remove services.bitcoind.package from your configuration. The service now uses
      nix-bitcoin.pkgs.bitcoind (Bitcoin Core) directly.
      See docs/upgrading.md, "Upgrading to config version 0.1.3".
    '')
  ];
}
