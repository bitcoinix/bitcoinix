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

Run `nix-collect-garbage -d`.

## Where is `sudo`?

After [CVE-2021-3156](https://www.openwall.com/lists/oss-security/2021/01/26/3),
we've replaced `sudo` with OpenBSD's `doas` for users of the `secure-node.nix` template.
It has greatly reduced complexity and is therefore less likely to be a source of
severe vulnerabilities in the future.
