# Nodeinfo

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

Run `nodeinfo` as user `operator` (or root) to see onion addresses and local addresses
for enabled services, and the node IDs of LND and Core Lightning. It prints JSON:
```shell
nodeinfo
nodeinfo | jq -r .bitcoind.onion_address
nodeinfo | jq -r .bitcoinix.revision
```
The `bitcoinix` entry is not a service: its `revision` is the bitcoinix git commit the
system is built from, with a `-dirty` suffix for a checkout with uncommitted changes.
It is `null` when the modules are imported without the bitcoinix flake; set
`bitcoinix.revision` yourself in that case.

The revision is baked into the `nodeinfo` script, so every bitcoinix update produces a
new system generation and boot entry, even when no package changed; no service restarts.
Set `bitcoinix.revision = null;` to opt out.

The entries of bitcoind, clightning, lnd, electrs, fulcrum, btcpayserver, rtl and mempool
include the `version` of the package the service runs.

Without arguments `nodeinfo` prints all entries. Arguments change that:
```shell
nodeinfo --version           # print only the bitcoinix revision, as a JSON string
nodeinfo bitcoind lnd        # print only these entries
```
See `nodeinfo --help`.

`nodeinfo` and `jq` are included in the `secure-node.nix` preset. Without the preset,
set `bitcoinix.nodeinfo.enable = true` and install `jq` for the example above.

## Troubleshoot onion addresses

The `onion-addresses` service only publishes valid Tor v3 onion addresses. If a
hostname file is unreadable, contains invalid content, or takes more than 10 seconds
to read, its address is omitted. Other valid addresses are still published, but
`onion-addresses.service` reports failure. `nodeinfo` then prints only
`error: service 'onion-addresses' is not running`. bitcoind, lnd and clightning with a
public onion service (`bitcoinix.onionServices.<service>.public`) don't start
without their address, and their journal shows the error of
`cat /var/lib/onion-addresses/services/<service>`.

Run `journalctl -u onion-addresses` to identify the affected
`/var/lib/tor/onion/<service>/hostname` file. It must be readable by the `tor` user
and contain a single v3 onion address, with at most one trailing newline. Once the
Tor-generated hostname file and its permissions are correct, run
`systemctl restart onion-addresses` as root, then retry `nodeinfo` and start the
services that failed.
