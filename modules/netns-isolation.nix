{ config, lib, pkgs, ... }:

with lib;
let
  options.nix-bitcoin.netns-isolation = {
    enable = mkEnableOption "netns isolation";

    addressblock = mkOption {
      type = types.ints.u8;
      default = 1;
      description = ''
        The address block N in 169.254.N.0/24, used as the prefix for netns addresses.
        169 and 170 aren't allowed, because those blocks hold cloud metadata addresses.
      '';
    };

    services = mkOption {
      default = {};
      description = ''
        Services that run in their own network namespace `nb-<name>`, keyed by
        the name of the service under `services`, e.g. `bitcoind`. An entry
        takes effect only while that service is enabled. The bitcoinix modules
        define the entries for the supported services.

        A namespace accepts incoming connections only from itself, from the
        host and from the namespaces linked by {option}`connections`.
        Connections from the host come from the bridge address
        `169.254.<addressblock>.10`, so every process in the host network
        namespace can reach the service, not only the services listed in
        {option}`connections`.
        Services with `tor.enforce` can also connect only to these addresses.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          id = mkOption {
            # TODO: Assert uniqueness
            type = types.ints.between 11 255;
            description = ''
              id for the netns, used for the IP address host part and
              for naming the interfaces. Must be unique. Must be greater than 10.
            '';
          };
          connections = mkOption {
            type = with types; listOf str;
            default = [];
            description = ''
              Services whose namespaces may exchange connections with this
              service's namespace. A connection works in both directions:
              `clightning.connections = [ "bitcoind" ]` also lets
              `bitcoind` connect to `clightning`. Entries for disabled
              services are ignored.
            '';
          };
        };
      });
    };

    restrictForwarding = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the host forwards only the traffic of the namespaces, that is
        the connections that a namespace opens and their replies. The host
        then drops all other forwarded IPv4 traffic, so a host on one of the
        node's networks can't reach another network through the node.

        Set this to `false` when the node routes for other networks on
        purpose, e.g. with `networking.nat`, Docker or a Tailscale subnet
        router. netns-isolation then adds no forwarding rules, and the host
        forwards between all its interfaces unless you filter this yourself.
      '';
    };

    netns = mkOption {
      readOnly = true;
      default = netns;
      description = "Exposes netns parameters.";
    };

    bridgeIp = mkOption {
      readOnly = true;
      default = bridgeIp;
      description = "IP of the netns bridge interface.";
    };

    usesNftables = mkOption {
      type = types.bool;
      internal = true;
      readOnly = true;
      default = bridgeUsesNftables || firewallUsesNftables;
      description = "Whether netns-isolation or the host firewall keeps iptables rules in the nftables ruleset.";
    };
  };

  cfg = config.nix-bitcoin.netns-isolation;

  netns = builtins.mapAttrs (n: v: {
    inherit (v) id;
    address = "169.254.${toString cfg.addressblock}.${toString v.id}";
    availableNetns = availableNetns.${n};
    netnsName = "nb-${n}";
  }) enabledServices;

  # Symmetric netns connection matrix
  # if clightning.connections = [ "bitcoind" ]; then
  #   availableNetns.bitcoind = [ "clighting" ];
  #   and
  #   availableNetns.clighting = [ "bitcoind" ];
  #
  # TODO-EXTERNAL:
  # Although negligible for our purposes, this calculation's runtime
  # is in the order of (number of connections * number of services),
  # because attrsets and lists are fully copied on each update with '//' or '++'.
  # This can only be improved with an update in the nix language.
  #
  availableNetns = let
    # base = { clightning = [ "bitcoind" ]; ... }
    base = builtins.mapAttrs (n: v:
      builtins.filter isEnabled v.connections
    ) enabledServices;
  in
    foldl (xs: s1:
      foldl (xs: s2:
        xs // { "${s2}" = xs.${s2} ++ [ s1 ]; }
      ) xs cfg.services.${s1}.connections
    ) base (builtins.attrNames base);

  enabledServices = filterAttrs (n: v: isEnabled n) cfg.services;
  isEnabled = x: config.services.${x}.enable;

  ip = "${pkgs.iproute2}/bin/ip";
  iptables = "${config.networking.firewall.package}/bin/iptables";
  # `pkgs.iptables-legacy` keeps its rules in the legacy xtables, outside the
  # nftables ruleset. Any other build, such as a renamed or wrapped one, counts
  # as iptables-nft. The bridge runs the iptables of `networking.firewall.package`.
  bridgeUsesNftables = "${config.networking.firewall.package}" != "${pkgs.iptables-legacy}";
  # The host firewall, which opens ports on `nb-br`, runs the first iptables
  # on its PATH, after only nftables' bin, which has no iptables. This is the
  # check of the WireGuard preset.
  firewallUsesNftables = config.networking.firewall.enable
    && findFirst (dir: dir != "${pkgs.nftables}/bin") null
         (splitString ":" (toString (config.systemd.services.firewall.environment.PATH or null)))
       != "${pkgs.iptables-legacy}/bin";
  # nb-netns-forward runs the iptables of the bridge, also when the host
  # firewall is off or runs iptables-legacy
  forwardUsesNftables = cfg.restrictForwarding && bridgeUsesNftables;
  # The firewall adds its reverse path check to the mangle tables. NixOS sets
  # `checkReversePath` to false when the kernel can't do the check.
  firewallChecksReversePath = firewallUsesNftables
    && config.networking.firewall.checkReversePath != false;
  # The tables where iptables-nft keeps these rules
  iptablesTables = optional bridgeUsesNftables "ip nat"
    ++ optional (forwardUsesNftables || firewallUsesNftables) "ip filter"
    ++ optional (firewallUsesNftables && config.networking.enableIPv6) "ip6 filter"
    ++ optional firewallChecksReversePath "ip mangle"
    ++ optional (firewallChecksReversePath && config.networking.enableIPv6) "ip6 mangle";
  iptablesTablesInNftables = filter (table: elem table iptablesTables)
    (mapAttrsToList (_: t: "${t.family} ${t.name}")
      (filterAttrs (_: t: t.enable) config.networking.nftables.tables));
  # These restore the rules after the last flush, in their boot order. A
  # reload replaces the rules in place. A restart of the firewall or of
  # nb-netns-forward first removes the rules that are still there.
  restoreRules = let
    commands = optional config.networking.firewall.enable "`systemctl reload-or-restart firewall.service`"
      ++ optional cfg.restrictForwarding "`systemctl reload-or-restart nb-netns-forward.service`"
      ++ [ "`systemctl restart nb-netns-bridge.service`" ];
  in if length commands == 1 then head commands
     else "${concatStringsSep ", " (init commands)} and ${last commands} in this order";

  bridgeIp = "169.254.${toString cfg.addressblock}.10";

  forwardChain = "nb-netns-forward";
  # iptables-restore replaces the rules of the chain and adds a missing FORWARD
  # jump in one step, so a reload never leaves forwarded traffic unfiltered. The
  # jump is appended, so ACCEPT rules that other tools insert at the top of
  # FORWARD still apply.
  # IPv4 only, like `net.ipv4.ip_forward`. The namespaces have no IPv6 addresses.
  addForwardRules = ''
    jumpRule=""
    if ! ${iptables} -w -C FORWARD -j ${forwardChain} 2>/dev/null; then
      jumpRule="-A FORWARD -j ${forwardChain}"
    fi
    {
      cat <<'EOF'
    *filter
    :${forwardChain} - [0:0]
    -A ${forwardChain} -i nb-br -j ACCEPT
    -A ${forwardChain} -o nb-br -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
    -A ${forwardChain} -j DROP
    EOF
      [[ ! $jumpRule ]] || echo "$jumpRule"
      echo COMMIT
    } | ${iptables}-restore -w --noflush
  '';
  # The kernel takes any value but 0 as on
  isOn = value: !(elem value [ null false 0 "0" ]);
  forwardingSetElsewhere =
    isOn (config.boot.kernel.sysctl."net.ipv4.conf.all.forwarding" or null);
in {
  inherit options;

  config = mkIf cfg.enable (mkMerge [

  # Base infrastructure
  {
    assertions = [
      {
        # `networking.firewall.package` defaults to `pkgs.nftables` whenever
        # `networking.nftables` is enabled, whatever the backend says, and that
        # package has no `bin/iptables`. Without the binary `nb-netns-bridge`
        # fails and every netns service stays down, so check the package the
        # rules run with, not only the backend. An explicit iptables package
        # next to nftables is fine. firewalld is not supported.
        assertion = config.networking.firewall.backend == "iptables"
          && lib.getName config.networking.firewall.package != "nftables";
        message = "`nix-bitcoin.netns-isolation` runs its iptables rules with `networking.firewall.package`, which is the nftables package without an iptables binary when `networking.nftables` is enabled, and firewalld is not supported. Disable `networking.nftables` and `services.firewalld`, or keep `networking.firewall.backend = \"iptables\"` and set `networking.firewall.package` to a package with `bin/iptables`, so that the firewall uses the iptables backend and package.";
      }
      {
        # With `flushRuleset`, every start, reload or stop of `nftables.service`
        # runs `flush ruleset`. NixOS turns it on by default when `ruleset` or
        # `rulesetFile` is set or `system.stateVersion` is older than 23.11.
        assertion = !(config.networking.nftables.enable && config.networking.nftables.flushRuleset)
                    || !(bridgeUsesNftables || firewallUsesNftables);
        message = "`nix-bitcoin.netns-isolation` needs the NAT rule of the namespace bridge, the forwarding rules of `nb-netns-forward` and the host firewall, which iptables-nft keeps in the nftables ruleset, but `networking.nftables.flushRuleset` deletes them whenever `nftables.service` starts, reloads or stops. Without the NAT rule, the namespaces can't reach anything beyond the host. Without the forwarding rules, the host forwards traffic between all its interfaces. The flush is on by default when `networking.nftables.ruleset` or `networking.nftables.rulesetFile` is set or `system.stateVersion` is older than 23.11. Move your nftables rules to `networking.nftables.tables` and set `networking.nftables.flushRuleset = false`. After deploying, reboot once or run ${restoreRules}, since the first reload or stop still runs the old flush.";
      }
      {
        # `nftables.service` deletes and recreates every table in
        # `networking.nftables.tables`. Raw `flush` or `delete` commands in
        # `ruleset`, `rulesetFile` or `extraDeletions` aren't checked.
        assertion = !config.networking.nftables.enable || iptablesTablesInNftables == [];
        message = "`nix-bitcoin.netns-isolation` needs the NAT rule of the namespace bridge, the forwarding rules of `nb-netns-forward` and the host firewall, which iptables-nft keeps in the tables `ip nat`, `ip filter`, `ip6 filter`, `ip mangle` and `ip6 mangle`, but `networking.nftables.tables` replaces ${concatStringsSep " and " (unique iptablesTablesInNftables)} whenever `nftables.service` starts or reloads, and deletes each one when `nftables.service` stops. Rename the table or use the `inet` family. After deploying, reboot once or run ${restoreRules}, since the first reload or stop still deletes the old table.";
      }
      {
        # Services with `tor.enforce` may reach the whole namespace subnet
        # 169.254.<addressblock>.0/24. Blocks 169 and 170 contain the well-known
        # cloud metadata addresses (169.254.169.254, 169.254.170.2), so keep the
        # subnet clear of them.
        assertion = !(builtins.elem cfg.addressblock [ 169 170 ]);
        message = "`nix-bitcoin.netns-isolation.addressblock` must not be 169 or 170: the subnet 169.254.${toString cfg.addressblock}.0/24 would include a cloud metadata address, which services with `tor.enforce` are then allowed to reach. Choose a different address block.";
      }
      {
        # A module that sets this forwards for other networks, and nb-netns-forward
        # would drop that traffic
        assertion = !cfg.restrictForwarding || !forwardingSetElsewhere;
        message = "`boot.kernel.sysctl.\"net.ipv4.conf.all.forwarding\"` is on, so this node forwards traffic for other networks. Modules like `networking.nat`, Docker (`virtualisation.docker`) and Tailscale with `useRoutingFeatures` set to `server` or `both` set it. With `nix-bitcoin.netns-isolation.restrictForwarding`, the host drops all forwarded traffic except that of the service namespaces. Set `nix-bitcoin.netns-isolation.restrictForwarding = false` to keep the forwarding. The host then forwards between all its interfaces, unless you filter forwarded traffic yourself.";
      }
    ];
    networking.dhcpcd.denyInterfaces = [ "nb-br" "nb-veth*" ];
    services.tor.client.socksListenAddress = {
      addr = bridgeIp;
      # Default NixOS values. These must be repeated when redefining this option.
      port = 9050;
      IsolateDestAddr = true;
    };
    services.i2pd.settings.sam.address = bridgeIp;
    # The upstream check starts i2pd in the build sandbox, where nb-br's
    # address does not exist. Custom setting errors are only caught at startup.
    # Validate the generated listener in the i2p VM scenario; see the 0.2.0
    # migration notes for checks after changing custom settings.
    services.i2pd.checkConfig = mkDefault false;
    networking.firewall.interfaces.nb-br.allowedTCPPorts = [
      config.services.tor.client.socksListenAddress.port
      (config.services.i2pd.settings.sam.port or 7656)
    ];
    # For the NAT of the namespaces. nb-netns-forward limits what the host forwards.
    boot.kernel.sysctl."net.ipv4.ip_forward" = true;

    systemd.services = {
      # Like the NixOS firewall, this starts before network-pre.target, so the
      # rules exist before any interface is set up and before nb-netns-bridge
      # starts. It also starts before systemd-sysctl turns on forwarding,
      # because interfaces that the initrd set up keep their addresses by
      # default. It runs after the firewall, also on a reload, because the
      # firewall script doesn't wait for the lock of iptables-legacy. Unlike
      # the firewall, it doesn't stop at shutdown, so the rules stay while the
      # services stop.
      # It's a unit of its own, because a change to nb-netns-bridge restarts
      # every namespaced service.
      nb-netns-forward = mkIf cfg.restrictForwarding {
        description = "nix-bitcoin netns forwarding rules";
        wantedBy = [ "sysinit.target" ];
        wants = [ "network-pre.target" ];
        after = [ "systemd-modules-load.service" "firewall.service" ];
        before = [ "network-pre.target" "systemd-sysctl.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = addForwardRules;
        # A switch replaces the rules without removing them first
        reloadIfChanged = true;
        reload = addForwardRules;
        # Delete every jump first, because a chain that's still referenced
        # can't be deleted
        preStop = ''
          while ${iptables} -w -D FORWARD -j ${forwardChain} 2>/dev/null; do :; done
          ${iptables} -w -F ${forwardChain} 2>/dev/null || true
          ${iptables} -w -X ${forwardChain} 2>/dev/null || true
        '';
      };

      # Due to a NixOS bug we can't currently use option `networking.bridges` to
      # setup the bridge while `networking.useDHCP` is enabled.
      nb-netns-bridge = {
        description = "nix-bitcoin netns bridge";
        wantedBy = [ "network-setup.service" ];
        partOf = [ "network-setup.service" ];
        before = [ "network-setup.service" ];
        after = [ "network-pre.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          # A stop or start that failed can leave the bridge behind with its
          # address. Delete only such a bridge, not a LAN bridge or VLAN that
          # has the same name.
          if [[ -e /sys/class/net/nb-br ]]; then
            addresses=$(${ip} -o -4 addr show dev nb-br | while read -r _ _ _ address _; do echo "$address"; done)
            if [[ -d /sys/class/net/nb-br/bridge && $addresses == "${bridgeIp}/24" ]]; then
              ${ip} link del nb-br
            else
              echo "Link nb-br exists, but it isn't a bridge with only the address ${bridgeIp}/24, like the bridge that a failed stop leaves behind. So netns-isolation doesn't delete it. Rename or delete this link, then run systemctl start nb-netns-bridge.service multi-user.target, which also starts the services in the namespaces." >&2
              exit 1
            fi
          fi
          ${ip} link add name nb-br type bridge
          ${ip} link set nb-br up
          ${ip} addr add ${bridgeIp}/24 brd + dev nb-br
          # Only masquerade traffic that leaves the bridge. With br_netfilter
          # loaded (e.g. by Docker), traffic between namespaces also passes
          # this chain and would get the bridge address as its source, which
          # every namespace accepts.
          ${iptables} -w -t nat -A POSTROUTING -s 169.254.${toString cfg.addressblock}.0/24 ! -o nb-br -j MASQUERADE
        '';
        # The rule is gone after a flush of the nftables ruleset. Delete the
        # bridge anyway, so that the next start works.
        preStop = ''
          ${iptables} -w -t nat -D POSTROUTING -s 169.254.${toString cfg.addressblock}.0/24 ! -o nb-br -j MASQUERADE 2> /dev/null || true
          ${ip} link del nb-br
        '';
      };

    } //
    (let
      makeNetnsServices = n: v: let
        veth = "nb-veth-${toString v.id}";
        peer = "nb-veth-br-${toString v.id}";
        inherit (v) netnsName;
        nsenter = "${pkgs.util-linux}/bin/nsenter";
        allowedNetnsAddresses = map (available: netns.${available}.address) v.availableNetns;
        allowedAddresses = concatStringsSep ","
          ([ "127.0.0.1,${bridgeIp},${v.address}" ] ++ allowedNetnsAddresses);

        setup = ''
          ${ip} netns add ${netnsName}
          ${ip} link add ${veth} type veth peer name ${peer}
          ${ip} link set ${veth} netns ${netnsName}
          # The peer link is never used directly, so don't auto-assign an IPv6 address
          echo 1 > /proc/sys/net/ipv6/conf/${peer}/disable_ipv6
          ${ip} link set ${peer} up
          ${ip} link set ${peer} master nb-br
          # net.mptcp.enabled is per network namespace, and a new one starts at
          # the kernel default. Pass the host's value in, so turning MPTCP off
          # on the host (like presets/hardened-extended does) covers the
          # services in their namespaces too. The copy is made when the netns
          # is set up, so a later change on the host needs a reboot.
          if [ -e /proc/sys/net/mptcp/enabled ]; then
            hostMptcp=$(cat /proc/sys/net/mptcp/enabled)
            export hostMptcp
          fi
          exec ${nsenter} --net=/run/netns/${netnsName} ${script "in-netns" setupInNetns}
        '';

        setupInNetns = ''
          ${ip} link set lo up
          if [ -n "''${hostMptcp:-}" ]; then
            echo "$hostMptcp" > /proc/sys/net/mptcp/enabled
          fi
          # The iptables rules below cover IPv4 only. Without this, the link
          # gets an IPv6 link-local address and other netns can reach it over
          # the bridge unfiltered.
          echo 1 > /proc/sys/net/ipv6/conf/${veth}/disable_ipv6
          ${ip} addr add ${v.address}/24 dev ${veth}
          ${ip} link set ${veth} up
          ${ip} route add default via ${bridgeIp}

          ${iptables} -w -P INPUT DROP
          # allow return traffic to outgoing connections initiated by the service itself
          ${iptables} -w -A INPUT -m conntrack --ctstate ESTABLISHED -j ACCEPT
          ${iptables} -w -A INPUT -s ${allowedAddresses} -j ACCEPT
        '' + optionalString (config.services.${n}.tor.enforce or false) ''
          ${iptables} -w -P OUTPUT DROP
          ${iptables} -w -A OUTPUT -d ${allowedAddresses} -j ACCEPT
        '';
        script = name: src: pkgs.writers.writeDash name ''
          set -e
          ${src}
        '';
        setupScript = script "setup" setup;
      in {
        "${n}" = {
          serviceConfig.NetworkNamespacePath = "/var/run/netns/${netnsName}";
          # A changed setup script restarts netns-${n}, which stops this
          # service because it requires netns-${n}. Restart this service
          # too, so that a switch starts it again.
          restartTriggers = [ setupScript ];
        };

        "netns-${n}" = rec {
          requires = [ "nb-netns-bridge.service" ];
          after = [ "nb-netns-bridge.service" ];
          requiredBy = [ "${n}.service" ];
          before = requiredBy;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = setupScript;
          };
          # Link deletion is implicit in netns deletion, but it sometimes only happens
          # after `netns delete` finishes. Add an extra `link del` to ensure that
          # the link is deleted before the service stops, which is needed for service
          # restart to succeed.
          preStop = ''
            ${ip} netns delete ${netnsName}
            ${ip} link del ${peer} 2> /dev/null || true
          '';

        };
      };
    in
      foldl (services: n:
        services // (makeNetnsServices n netns.${n})
      ) {} (builtins.attrNames netns)
    );
  }

  # Service-specific config
  {
    nix-bitcoin.netns-isolation.services = {
      bitcoind = {
        id = 12;
      };
      clightning = {
        id = 13;
        connections = [ "bitcoind" ];
      };
      lnd = {
        id = 14;
        connections = [ "bitcoind" ];
      };
      electrs = {
        id = 16;
        connections = [ "bitcoind" ];
      };
      nginx = {
        id = 21;
      };
      nbxplorer = {
        id = 23;
        connections = [ "bitcoind" ];
      };
      btcpayserver = {
        id = 24;
        connections = [ "nbxplorer" ]
                      ++ optional (config.services.btcpayserver.lightningBackend == "lnd") "lnd";
        # communicates with clightning over rpc socket
      };
      charge-lnd = {
        id = 28;
        connections = [ "lnd" "electrs" ];
      };
      rtl = {
        id = 29;
        connections = let
          nodes = config.services.rtl.nodes;
        in
          optional nodes.lnd.enable "lnd" ++
          optional nodes.clightning.enable "clightning";
      };
      fulcrum = {
        id = 31;
        connections = [ "bitcoind" ];
      };
      mempool = {
        id = 32;
        connections = [
          "bitcoind"
          "nginx"
          config.services.mempool.electrumServer
        ];
      };
      orchard = {
        id = 37;
        connections = [ "cdk-mintd" "nginx" ];
      };
      cdk-mintd = {
        id = 36;
        connections = [ "nginx" ]
          ++ optional (config.services.cdk-mintd.backend == "lnd") "lnd"
          ++ optional config.services.cdk-mintd.onchain.enable "bitcoind";
        # Core Lightning uses a Unix socket.
      };
      unbeholden-lnurl = {
        id = 34;
        connections = [ config.services.unbeholden-lnurl.backend "nginx" ];
      };
      unbeholden-wallet = {
        id = 33;
        connections = [ config.services.unbeholden-wallet.electrumServer "nginx" ];
      };
    };

    services.bitcoind = let
      allowip = [
        bridgeIp # Every process in the host netns, e.g. the operator user
        netns.bitcoind.address
      ] ++ map (n: netns.${n}.address) netns.bitcoind.availableNetns;
    in {
      address = netns.bitcoind.address;
      rpc.address = netns.bitcoind.address;
      rpc.allowip = allowip;
      rest.localSources = allowip;
    };

    services.clightning.address = netns.clightning.address;
    services.clightning.plugins.clnrest.address = netns.clightning.address;

    services.lnd = {
      address = netns.lnd.address;
      rpcAddress = netns.lnd.address;
      restAddress = netns.lnd.address;
    };

    services.electrs.address = netns.electrs.address;

    services.fulcrum.address = netns.fulcrum.address;

    services.nbxplorer.address = netns.nbxplorer.address;
    services.btcpayserver.address = netns.btcpayserver.address;

    services.rtl.address = netns.rtl.address;

    services.mempool.address = netns.mempool.address;
    services.mempool.frontend.address = netns.nginx.address;

    services.cdk-mintd.address = netns.cdk-mintd.address;
    services.orchard.address = netns.orchard.address;

    services.unbeholden-lnurl.address = netns.unbeholden-lnurl.address;

    services.unbeholden-wallet.address = netns.unbeholden-wallet.address;
  }
  ]);
}
