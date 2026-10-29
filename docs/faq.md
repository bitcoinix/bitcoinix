# FAQ

## Why does Core Lightning fail on my pruned node?

You may see `lightning-cli: Connecting to 'lightning-rpc': Connection refused`. Check the
log with `journalctl -eu clightning`. Core Lightning needs every block since it last ran.
When Bitcoin Core has already pruned one of them, the `bcli` plugin asks Bitcoin Core to
fetch it from a peer with `getblockfrompeer`. This needs connected peers that still serve
the block.

`getblockfrompeer` is unavailable when `services.clightning.useBcliPlugin` is off,
e.g. with the `trustedcoin` plugin, which fetches blocks from public block explorers instead.

If the node is new and holds no funds or channels, you can start over:

```shell
systemctl stop clightning
find /var/lib/clightning -mindepth 1 -delete
systemctl start clightning
```

Never do this on a node with funds or channels. `/var/lib/clightning` holds `hsm_secret`
and the channel database.

## How do I free disk space used by Nix?

Each deployment keeps the previous system generations, so you can roll back. Run
`nix-collect-garbage -d` as root to delete the old generations and everything that only
they use. You can't roll back to the deleted generations afterwards.

To clean up automatically, set the NixOS option
[`nix.gc.automatic`](https://search.nixos.org/options?query=nix.gc), e.g.
with `nix.gc.options = "--delete-older-than 30d"`.

## Where is `sudo`?

The [`secure-node.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/modules/presets/secure-node.nix)
preset disables `sudo` and enables OpenBSD's `doas`, which is much smaller. It also adds the
shell alias `sudo` for `doas`. This followed
[CVE-2021-3156](https://www.openwall.com/lists/oss-security/2021/01/26/3) in `sudo`.

To run commands as root, add your user to the `wheel` group, e.g.
`users.users.operator.extraGroups = [ "wheel" ];`. `doas` asks members of `wheel` for their
password, and the `operator` user has none by default. Set one as root with `passwd operator`.

## How do I see my node's onion addresses?

Set `nix-bitcoin.nodeinfo.enable = true;` (the `secure-node.nix` preset does) and run
`nodeinfo` as root or as the operator user. It lists the enabled services with their local
and onion addresses. The operator can also read the onion addresses of all active onion
services in `/var/lib/onion-addresses/<operator name>/`. See [nodeinfo](services.md#nodeinfo).

## How do I run a command in a service's network namespace?

With `nix-bitcoin.netns-isolation.enable = true;`, each service runs in a network namespace
named `nb-<service>`. Run the command as root with `ip netns exec nb-<service> <command>`,
e.g. `ip netns exec nb-bitcoind ss -tlnp`. The `netns-exec` wrapper has been removed.

## Why can't I run `bitcoin-cli`, `lightning-cli` or `lncli` as my user?

These commands work as root and as the operator user. Enable it with
`nix-bitcoin.operator.enable = true;` (the `secure-node.nix` preset does), or make your
existing user the operator with `nix-bitcoin.operator.name = "<your user>";`. The operator
joins the groups of the enabled services, and runs `lncli` as the `lnd` user through `doas`
or `sudo`.
