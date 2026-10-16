# Representative bitcoinix node: the secure-node preset plus the shipped
# services and backups, i.e. the recommended deployment. Hardware wallets are
# host tooling, not node services.
#
# CVE-scan target (test/ci/cve-scan.sh): vulnix scans this system's RUNTIME
# closure, the software a user actually runs (bitcoind, clightning, lnd,
# electrs, fulcrum, btcpayserver, nbxplorer, mempool, rtl, kernel, systemd,
# openssl, ...), NOT build-time dependencies like compilers, which are what a
# test-derivation closure drags in and are irrelevant to a deployed node.
#
# Built with:  nix build --impure -f test/ci/scan-node.nix
let
  f = builtins.getFlake (builtins.toString ./../..);
  lib = f.inputs.nixpkgs.lib;
in
(lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    f.nixosModules.default
    # The recommended deployment, not the bare service set: secure-node pulls
    # in tor (client + onion services, the largest continuously exposed parsing
    # surface on a real node), the operator/doas setup, nodeinfo and the preset
    # infrastructure; backups adds duplicity. Without these the scan would skip
    # exactly the components a deployed node exposes.
    "${f.outPath}/modules/presets/secure-node.nix"
    # The WireGuard preset adds wireguard-tools, qrencode and lndconnect to the
    # closure of nodes that use it.
    "${f.outPath}/modules/presets/wireguard.nix"
    {
      nix-bitcoin.generateSecrets = true;
      nix-bitcoin.nodeinfo.enable = true;
      services.backups.enable = true;
      services.bitcoind.enable = true;

      services.clightning.enable = true;
      services.clightning.plugins.clnrest.enable = true;
      # Encrypted replication pulls in gocryptfs (and sshfs for remote targets)
      services.clightning.replication = {
        enable = true;
        encrypt = true;
        local.directory = "/var/backup/clightning";
      };
      services.lnd.enable = true;
      # clightning and lnd both default to 9735 (asserted in modules/lnd.nix)
      services.lnd.port = 9736;
      services.charge-lnd.enable = true;

      services.electrs.enable = true;
      services.fulcrum.enable = true;
      # electrs and fulcrum both default to 50001 (asserted in modules/fulcrum.nix)
      services.fulcrum.port = 50002;

      services.btcpayserver.enable = true;
      services.btcpayserver.lightningBackend = "lnd";
      services.mempool.enable = true;
      services.rtl.enable = true;
      # RTL asserts that at least one node interface is enabled
      services.rtl.nodes.clightning.enable = true;
      services.rtl.nodes.lnd.enable = true;

      # Minimal boot/fs so the system evaluates and builds a toplevel.
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
      system.stateVersion = "26.05";
    }
  ];
}).config.system.build.toplevel
