{ config, pkgs, lib, ... }:

# Create a WireGuard server with a single peer.
# Private/public keys are created via the secrets system.
# Add helper binaries `nix-bitcoin-wg-connect` and optionally `lndconnect-wg`,
# `lnconnect-clnrest-wg`.

# See ../../docs/services.md ("Use Zeus (mobile lightning wallet) via WireGuard")
# for usage instructions.

# This is a rather opinionated implementation that lacks the flexibility offered by
# other bitcoinix modules, so ship this as a `preset`.
# Some users will prefer to use `lndconnect` with their existing WireGuard or Tailscale setup.

with lib;
let
  options.nix-bitcoin.wireguard = {
    subnet = mkOption {
      type = types.str;
      default = "10.10.0";
      description = "The /24 subnet of the wireguard network.";
    };
    restrictPeer = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Prevent the peer from connecting to any addresses except for the WireGuard server address.
      '';
    };
  };

  cfg = config.nix-bitcoin.wireguard;
  wgSubnet = cfg.subnet;
  inherit (config.networking.wireguard.interfaces) wg-nb;
  inherit (config.services)
    lnd
    clightning;
  inherit (clightning.plugins) clnrest;

  lndconnect = lnd.enable && lnd.lndconnect.enable;
  lnconnect-clnrest = clnrest.enable && clnrest.lnconnect.enable;
  # The firewall rules below guard these REST APIs and enforce `restrictPeer`.
  needsFirewallRules = lndconnect || lnconnect-clnrest || cfg.restrictPeer;
  iptablesTablesInNftables = mapAttrsToList (_: t: "${t.family} ${t.name}")
    (filterAttrs (_: t: t.enable && t.name == "filter" && elem t.family [ "ip" "ip6" ])
      config.networking.nftables.tables);
  # `pkgs.iptables-legacy` keeps its rules in the legacy xtables, outside the
  # nftables ruleset. It ships `bin/iptables`, so it's the iptables the firewall
  # runs when its bin comes first on the service's PATH, after only nftables' bin,
  # which has no iptables. Anything else, such as a renamed or wrapped build,
  # counts as iptables-nft.
  firewallUsesIptablesLegacy =
    findFirst (dir: dir != "${pkgs.nftables}/bin") null
      (splitString ":" (toString (config.systemd.services.firewall.environment.PATH or null)))
    == "${pkgs.iptables-legacy}/bin";
  iptablesUsesNftables = !firewallUsesIptablesLegacy;

  serverAddress = "${wgSubnet}.1";
  peerAddress = "${wgSubnet}.2";

  secretsDir = config.nix-bitcoin.secretsDir;

  wgConnectUser = if config.nix-bitcoin.operator.enable
                  then config.nix-bitcoin.operator.name
                  else "root";

  # A script that prints a QR code to connect a peer to the server.
  # The QR code encodes a wg-quick config that can be imported by the wireguard
  # mobile app.
  wgConnect = pkgs.writers.writeBashBin "nix-bitcoin-wg-connect" ''
    set -euo pipefail
    text=
    host=
    for arg in "$@"; do
      case $arg in
        --text)
          text=1
          ;;
        *)
          host=$arg
          ;;
      esac
    done

    if [[ ! $host ]]; then
      # Use lndconnect to fetch the external ip.
      # This internally uses https://github.com/GlenDC/go-external-ip, which
      # queries a set of external ip providers.
      host=$(
        ${getExe config.nix-bitcoin.pkgs.lndconnect} --url --nocert \
          --configfile=/dev/null --adminmacaroonpath=/dev/null \
          | sed -nE 's|.*?/(.*?):.*|\1|p'
      )
    fi

    config="[Interface]
    PrivateKey = $(cat ${secretsDir}/wg-peer-private-key)
    Address = ${peerAddress}/24

    [Peer]
    PublicKey = $(cat ${secretsDir}/wg-server-public-key)
    AllowedIPs = ${wgSubnet}.0/24
    Endpoint = $host:${toString wg-nb.listenPort}
    PersistentKeepalive = 25
    "

    if [[ $text ]]; then
      echo "$config"
    else
      echo "$config" | ${getExe pkgs.qrencode} -t UTF8 -o -
    fi
  '';
in {
  inherit options;

  config = {
    assertions = [
      {
        # Don't support `netns-isolation` for now to keep things simple
        assertion = !(config.nix-bitcoin.netns-isolation.enable or false);
        message = "`nix-bitcoin.wireguard` is not compatible with `netns-isolation`.";
      }
      {
        # The REST APIs below are bound to 0.0.0.0 and are protected only by the
        # `extraCommands` rules, which also enforce `restrictPeer`. `extraCommands`
        # run only with the iptables backend: NixOS rejects a non-empty
        # `extraCommands` under nftables, and firewalld silently ignores them.
        # The backend alone is not enough: `networking.firewall.package` defaults
        # to `pkgs.nftables` whenever `networking.nftables` is enabled, whatever
        # the backend says, and the firewall service's PATH holds only that
        # package plus `networking.firewall.extraPackages`. Without an `iptables`
        # binary on it the service fails at its first rule and the box runs with
        # no firewall at all, so check what the rules run with. An iptables
        # package next to nftables, as the package or in extraPackages, is fine.
        # This catches the default that `networking.nftables` sets, not every
        # package whose iptables doesn't work on the running kernel.
        assertion = !needsFirewallRules
                    || (config.networking.firewall.enable
                        && config.networking.firewall.backend == "iptables"
                        && (lib.getName config.networking.firewall.package != "nftables"
                            || lib.any (p: lib.getName p == "iptables") config.networking.firewall.extraPackages));
        message = "`nix-bitcoin.wireguard` protects the REST API of the enabled `*connect` helpers (bound to 0.0.0.0) and enforces `restrictPeer` only through `networking.firewall.extraCommands`, which run only with the iptables backend and need `iptables` on the firewall service's PATH (`networking.firewall.package` is ${lib.getName config.networking.firewall.package}). Enable `networking.firewall` and disable `networking.nftables` and `services.firewalld`, or keep `networking.firewall.backend = \"iptables\"` and provide `iptables` through `networking.firewall.package` or `networking.firewall.extraPackages`.";
      }
      {
        # `pkgs.iptables` is iptables-nft, so the rules above live in the nftables
        # ruleset. With `flushRuleset`, every start or reload of `nftables.service`
        # runs `flush ruleset` and deletes them while `firewall.service` stays
        # active. NixOS turns it on by default when `ruleset` or `rulesetFile` is
        # set or `system.stateVersion` is older than 23.11. Rules in
        # `networking.nftables.tables` don't need it. iptables-legacy is exempt:
        # its rules aren't part of the nftables ruleset, so a flush keeps them.
        assertion = !needsFirewallRules || !iptablesUsesNftables
                    || !(config.networking.nftables.enable && config.networking.nftables.flushRuleset);
        message = "`nix-bitcoin.wireguard` needs its `networking.firewall.extraCommands` rules to stay in place, but `networking.nftables.flushRuleset` deletes them whenever `nftables.service` starts or reloads. It's on by default when `networking.nftables.ruleset` or `networking.nftables.rulesetFile` is set or `system.stateVersion` is older than 23.11. Move your nftables rules to `networking.nftables.tables` and set `networking.nftables.flushRuleset = false`. Restart `firewall.service` once after deploying, since the first reload still runs the old flush.";
      }
      {
        # iptables-nft keeps the firewall in the `filter` tables of the `ip` and
        # `ip6` families. `nftables.service` deletes and recreates every table in
        # `networking.nftables.tables`, so a table with the same family and name
        # would replace the firewall. Raw `flush` or `delete` commands in
        # `ruleset`, `rulesetFile` or `extraDeletions` aren't checked.
        # iptables-legacy doesn't use these tables, so it's exempt.
        assertion = !needsFirewallRules || !iptablesUsesNftables
                    || !config.networking.nftables.enable
                    || iptablesTablesInNftables == [];
        message = "`nix-bitcoin.wireguard` needs its `networking.firewall.extraCommands` rules, which iptables-nft keeps in the `ip filter` and `ip6 filter` tables, but `networking.nftables.tables` replaces ${concatStringsSep " and " iptablesTablesInNftables} on every start or reload of `nftables.service`. Rename the table or use the `inet` family, then restart `firewall.service` once after deploying, since the first reload still deletes the old table.";
      }
    ];

    networking.wireguard.interfaces.wg-nb = {
      ips = [ "${serverAddress}/24" ];
      listenPort = mkDefault 51820;
      privateKeyFile = "${secretsDir}/wg-server-private-key";
      allowedIPsAsRoutes = false;
      peers = [
        {
          # The pubkey is only known at runtime (secrets file). nixpkgs splices
          # `publicKey` into the peer unit scripts inside double quotes, so pass
          # a shell variable that is set and validated by `readPeerPubkey` below.
          name = "peer0";
          publicKey = "$publicKey";
          allowedIPs = [ "${peerAddress}/32" ];
        }
      ];
    };

    systemd.services = {
      wireguard-wg-nb = rec {
        wants = [ "nix-bitcoin-secrets.target" ];
        after = wants;
      };

      wireguard-wg-nb-peer-peer0 = let
        pubkeyFile = "${secretsDir}/wg-peer-public-key";
        # Accept only a canonical `wg pubkey` output: 32 bytes as base64.
        # The last char before `=` encodes 2 bits of padding, which must be zero.
        readPeerPubkey = mkBefore ''
          publicKey=$(<"${pubkeyFile}")
          if [[ ! $publicKey =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
            echo "${pubkeyFile} does not contain a valid WireGuard public key" >&2
            exit 1
          fi
        '';
      in {
        # nixpkgs appends ` (<publicKey>)`, which would be a literal `$publicKey` here
        description = mkForce "WireGuard Peer - wg-nb - peer0";
        script = readPeerPubkey;
        postStop = readPeerPubkey;
      };
    };

    environment.systemPackages = [
      wgConnect
    ] ++ (optional lndconnect
      (pkgs.writers.writeBashBin "lndconnect-wg" ''
        exec lndconnect --host "${serverAddress}" --nocert "$@"
      '')
    ) ++ (optional lnconnect-clnrest
      (pkgs.writers.writeBashBin "lnconnect-clnrest-wg" ''
        exec lnconnect-clnrest --host "${serverAddress}" --nocert "$@"
      '')
    );

    networking.firewall = let
      restrictPeerRule = "-s ${peerAddress} ! -d ${serverAddress} -j REJECT";
    in {
      allowedUDPPorts = [ wg-nb.listenPort ];

      # Accept REST traffic from the WireGuard subnet only when it arrived via `wg-nb`
      # and is addressed to the server's tunnel address. `-s` alone would also match
      # a spoofed subnet source address on any other interface, e.g. the LAN, and
      # without `-d` a peer could reach the ports via another local address of the
      # server, which `restrictPeer` is meant to rule out.
      extraCommands =
        optionalString lndconnect ''
          iptables -w -A nixos-fw -i wg-nb -p tcp -s ${wgSubnet}.0/24 -d ${serverAddress} --dport ${toString lnd.restPort} -j nixos-fw-accept
        ''
        + optionalString lnconnect-clnrest ''
          iptables -w -A nixos-fw -i wg-nb -p tcp -s ${wgSubnet}.0/24 -d ${serverAddress} --dport ${toString clnrest.port} -j nixos-fw-accept
        ''
        # Insert first: NixOS fills `nixos-fw` with its ACCEPT rules (`allowedTCPPorts`) before `extraCommands`.
        # The rule only matches peer traffic not sent to `serverAddress`, so tunnel flows still pass.
        + optionalString cfg.restrictPeer ''
          iptables -w -I nixos-fw 1 ${restrictPeerRule}
          iptables -w -I FORWARD 1 ${restrictPeerRule}
        '';

      extraStopCommands =
        # Rules added to chain `nixos-fw` are automatically removed when restarting
        # the NixOS firewall service.
        mkIf cfg.restrictPeer ''
          iptables -w -D FORWARD ${restrictPeerRule} || :
        '';
    };

    # Listen on all addresses, including `serverAddress`.
    # This is safe because the listen ports are secured by the firewall.
    services.lnd = mkIf lndconnect {
      restAddress = "0.0.0.0";
      tor.enforce = false;
    };

    services.clightning.plugins.clnrest.address = mkIf lnconnect-clnrest "0.0.0.0";
    # clnrest runs inside `clightning.service`
    services.clightning.tor.enforce = mkIf lnconnect-clnrest false;

    nix-bitcoin.secrets = {
      wg-server-private-key = {};
      wg-server-public-key = { user = wgConnectUser; group = "root"; };
      wg-peer-private-key = { user = wgConnectUser; group = "root"; };
      wg-peer-public-key = {};
    };

    nix-bitcoin.generateSecretsCmds.wireguard = let
      wg = "${pkgs.wireguard-tools}/bin/wg";
    in ''
      makeWireguardKey() {
        local name=$1
        local priv=wg-$name-private-key
        local pub=wg-$name-public-key
        local derivedPub
        if isAbsent "$priv"; then
          writeSecret "$priv" ${wg} genkey
        fi
        checkKey "$priv" "the WireGuard clients set up with the current keys"
        # Derive the public key on every run, so that it always matches
        derivedPub=$(${wg} pubkey < "$priv")
        if [[ $(cat "$pub" 2>/dev/null) != "$derivedPub" ]]; then
          writeSecret "$pub" echo "$derivedPub"
        fi
      }
      makeWireguardKey server
      makeWireguardKey peer
    '';
  };
}
