{ config, pkgs, lib, ... }:

# Create a WireGuard server with a single peer.
# Private/public keys are created via the secrets system.
# Add helper binaries `nix-bitcoin-wg-connect` and optionally `lndconnect-wg`,
# `lnconnect-clnrest-wg`, `lndconnect-clightning-wg`.

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
    clightning
    clightning-rest;
  inherit (clightning.plugins) clnrest;

  lndconnect = lnd.enable && lnd.lndconnect.enable;
  lnconnect-clnrest = clnrest.enable && clnrest.lnconnect.enable;
  lndconnect-clightning = clightning-rest.enable && clightning-rest.lndconnect.enable;

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
        assertion = !(lndconnect || lnconnect-clnrest || lndconnect-clightning || cfg.restrictPeer)
                    || (config.networking.firewall.enable && config.networking.firewall.backend == "iptables");
        message = "`nix-bitcoin.wireguard` protects the REST API of the enabled `*connect` helpers (bound to 0.0.0.0) and enforces `restrictPeer` only through `networking.firewall.extraCommands`, which run only with the iptables backend. Enable `networking.firewall` and disable `networking.nftables` and `services.firewalld`, so that the firewall defaults to the iptables backend.";
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
    ) ++ (optional lndconnect-clightning
      (pkgs.writers.writeBashBin "lndconnect-clightning-wg" ''
        exec lndconnect-clightning --host "${serverAddress}" --nocert "$@"
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
        + optionalString lndconnect-clightning ''
          iptables -w -A nixos-fw -i wg-nb -p tcp -s ${wgSubnet}.0/24 -d ${serverAddress} --dport ${toString clightning-rest.port} -j nixos-fw-accept
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

    services.clightning-rest = mkIf lndconnect-clightning {
      address = "0.0.0.0";
      tor.enforce = false;
    };

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
        if [[ ! -e $priv ]]; then
          ${wg} genkey > $priv
        fi
        if [[ $priv -nt $pub ]]; then
          ${wg} pubkey < $priv > $pub
        fi
      }
      makeWireguardKey server
      makeWireguardKey peer
    '';
  };
}
