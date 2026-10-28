# Deploying with Colmena

This example deploys a bitcoinix node with [Colmena](https://github.com/nix-community/colmena)
([manual](https://colmena.cli.rs/unstable/)). CI builds it on every pull request, so it
works with the current bitcoinix.

The hive in [`flake.nix`](flake.nix) defines one node, `fullnode`: the
[secure-node preset](../../modules/presets/secure-node.nix) with bitcoind, clightning with
clnrest, RTL, mempool with fulcrum, an nginx reverse proxy for mempool on the local network,
and backups. The node can be any machine that runs NixOS, e.g. a Raspberry Pi 4, an old
laptop or a VM.

| File | Contents |
|---|---|
| [`flake.nix`](flake.nix) | inputs, the hive, and a dev shell with `colmena` |
| [`common.nix`](common.nix) | settings for every node: Nix, SSH, users (optional, except root's SSH access) |
| [`configs/fullnode/configuration.nix`](configs/fullnode/configuration.nix) | the bitcoinix services |
| [`configs/fullnode/hardware-configuration.nix`](configs/fullnode/hardware-configuration.nix) | placeholder for your node's boot loader and disks |

## Usage

1. Copy this directory and adapt it. Look for `FIXME` and placeholders like `<your_pubkey>`:
   - the root SSH keys in `common.nix`
   - `deployment.targetHost` in `flake.nix`
   - the network interface in `configuration.nix`
   - replace `hardware-configuration.nix` with the output of `nixos-generate-config` on your
     node. This example keeps the bitcoind and fulcrum data on an extra disk at `/mnt/data`;
     mount one there or drop the `dataDir` lines in `configuration.nix`.

2. Pin `bitcoinix` in `flake.nix` to the latest release tag and verify that tag
   (see [Installation](../../docs/install.md)). Commit the `flake.lock` that Nix creates.

3. Optional: use the bitcoinix binary cache with `cachix use bitcoinix`.

4. Enter the dev shell with `nix develop` and deploy:

   ```shell
   colmena build --on fullnode            # build only
   colmena apply --on fullnode boot       # activate on the next boot
   ssh root@fullnode.example.com reboot
   ```

   Prefer `boot` and a reboot, above all when you update bitcoinix: `switch` activates the new
   configuration on the running node, which can cause problems.

   `buildOnTarget = true` builds the system on the node, for its own architecture, so you
   need no cross-building and can deploy from macOS.

bitcoinix generates its own secrets on the node (`nix-bitcoin.generateSecrets`), in
`/etc/nix-bitcoin-secrets`. Back them up yourself: they are not part of the flake.
