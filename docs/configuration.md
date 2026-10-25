# Managing your deployment

> [!NOTE]
> This document is inherited from nix-bitcoin, the predecessor project. It is a work in progress and may be outdated.

> [!WARNING]
> This documentation may be outdated or contain installation steps that do not work with
> bitcoinix yet.
> Please report problems at <https://github.com/bitcoinix/bitcoinix/issues>.

This section applies to users of the deployment method described in the [installation guide](./install.md).

## Deployment shell
Run command `nix-shell` in your deployment directory.\
You now have access to deployment commands:

- `deploy`\
  Deploy the current configuration to your node.
- `eval-config`\
  Locally evaluate the configuration. This is useful to check for configuration errors.
- `h`, `help`\
  Show help

## Updating bitcoinix
Run `update-nix-bitcoin` from the deployment shell.\
This fetches the latest release, verifies the signature on its release tag and updates `nix-bitcoin-release.nix`.\
It refuses to switch to a release older than the one currently pinned. To downgrade on purpose,
run `fetch-release.sh` with `releaseVersion=<version>` and write its output to `nix-bitcoin-release.nix`.

### Upgrading to config version 0.1.1

Liquid support has been removed, including the Elements daemon, liquid-swap, and
BTCPay Server's LBTC integration. Liquid peg-outs were suspended after the
September 2026 Elements consensus bug
([incident assessment](https://blog.liquid.net/liquid-network-security-incident-assessment/)).

If you used Liquid, remove `services.liquidd`, `services.btcpayserver.lbtc`, and any
Liquid-specific onion service or network namespace settings from your configuration.

Upgrading does not delete Liquid data. These files stay on the node:
- the data directory (default: `/var/lib/liquidd`), which holds your Liquid wallets
- the secret `liquid-rpcpassword` in the secrets directory (default: `/etc/nix-bitcoin-secrets`)
- the onion service keys in `/var/lib/tor/onion/liquidd`, if Liquid had an onion service
  (the default with the `secure-node.nix` preset)

The backups service no longer includes the data directory. To keep backing up the
wallets without the chain data (as before, unless `with-bulk-data` was set), add:
```nix
services.backups.extraFiles = [
  "- /var/lib/liquidd/*/blocks"
  "- /var/lib/liquidd/*/chainstate"
  "- /var/lib/liquidd/*/indexes"
  "/var/lib/liquidd"
];
```
To access the wallets later, run upstream Elements Core 23.3.4 or later on a copy of
the data directory. Earlier versions, including the `elementsd` package in
nixpkgs 26.05, lack the fix for that bug.
Delete the files above once you no longer need them.

The `netns-exec` wrapper has been removed. Its namespace allowlist had been empty
since joinmarket was removed, so it rejected every namespace. To run a command in a
service network namespace, use `sudo ip netns exec nb-<service> <command>`.
If you set `nix-bitcoin.netns-isolation.allowedUser`, remove it from your configuration.

Lightning Pool and Lightning Loop support, including RTL's Loop integration, has
also been removed. Remove `services.lightning-pool`, `services.lightning-loop`,
`services.rtl.nodes.lnd.loop`, and any Pool- or Loop-specific onion service or
network namespace settings from your configuration.

If you still need either service, arrange a separately managed deployment before
upgrading. The services stop running after the upgrade, and their packages and
CLI wrappers are no longer installed by bitcoinix. Existing data directories
(default: `/var/lib/lightning-pool` and `/var/lib/lightning-loop`) and Loop secrets
(`loop-key` and `loop-cert` in the secrets directory) are retained. Keep these
files for the separately managed deployment.

Before upgrading, make sure no Loop swap is in progress (`loop listswaps`). Once a
Loop Out has revealed its preimage, its sweep must confirm before the HTLC expires,
otherwise the swap amount is lost. Pool account funds stay locked until the
account expires; to recover them, run `poold` with the retained data directory.

BTCPay Server's wallet UTXO scan is now disabled by default. The `btcpayserver`
RPC user no longer has permission to call `scantxoutset`, because a scan can keep
bitcoind busy for minutes. If you use this feature, explicitly restore permission:

```nix
services.bitcoind.rpc.users.btcpayserver.rpcwhitelist = [ "scantxoutset" ];
```

If you do not use wallet UTXO scanning, leave it disabled and acknowledge the
change by updating the config version below.

The charge-lnd macaroon now grants read access and write access only to
`UpdateChannelPolicy` and `UpdateChanStatus`. The previous broad `offchain:write`
grant also allowed sending payments and abandoning channels. lnd regenerates
`/run/lnd/charge-lnd.macaroon` with the restricted permissions when it restarts
during deployment. Regeneration does not revoke old copies: they remain valid
with their original permissions. Do not reuse them. If another application used
this macaroon, give it a separate macaroon with the permissions it needs via
`services.lnd.macaroons`.

`lnconnect-clnrest` now includes clnrest's server certificate (`server.pem`) in
direct connection URLs. Previously it included the mutual-TLS client certificate
(`client.pem`), which did not match the certificate presented by clnrest. Regenerate
direct connection URLs and reconnect clients. Tor and WireGuard URLs use `--nocert`
and are unaffected.

c-lightning-REST support has been removed because it is no longer maintained.
Remove `services.clightning-rest` (or the legacy `services.rtl.cl-rest`) and any
associated onion service or network namespace settings from your configuration.
Use the clnrest plugin for Core Lightning's REST API:

```nix
services.clightning = {
  enable = true;
  plugins.clnrest = {
    enable = true;
    # Optional: connection helper and access via Tor
    lnconnect = {
      enable = true;
      onion = true;
    };
  };
};
```

clnrest uses runes for authentication instead of c-lightning-REST macaroons and
listens on port 3010 by default. Reconnect clients using `lnconnect-clnrest`
instead of `lndconnect-clightning`, or `lnconnect-clnrest-wg` instead of
`lndconnect-clightning-wg` with the WireGuard preset. See
[connecting via Tor](./services.md#use-zeus-mobile-lightning-wallet-via-tor) and
[connecting via WireGuard](./services.md#use-zeus-mobile-lightning-wallet-via-wireguard).
RTL already uses clnrest and enables it automatically for its Core Lightning node.

Custom API clients must switch to `POST /v1/<rpc-method>` with JSON parameters and
handle native Core Lightning RPC responses. The convenience endpoints `getBalance`,
`getFees`, and `channel/localRemoteBal` are gone; calculate their summaries from
`listfunds`, `getinfo`, and `listpeerchannels`. The old `/v1/ws` protocol is also
replaced by clnrest's notification streaming. See the
[upstream migration guide](https://github.com/Ride-The-Lightning/c-lightning-REST#migrating).

clnrest runs within `clightning.service` and shares Core Lightning's network
namespace and sandbox. There is no separate REST service or API-specific Tor
enforcement setting. `services.clightning.tor.enforce` applies to both; the WireGuard
preset disables enforcement for that service to allow connections over the tunnel.

Swagger documentation is served on the REST API port at `/`, instead of a separate
`docPort`. If you used `extraConfig.DOMAIN` for a custom certificate hostname,
supply suitable certificates with the `clnrest-certs` option through
`services.clightning.extraConfig`. When using a custom certificate directory, pass
`--tlscertpath=/path/to/certs/server.pem` to `lnconnect-clnrest` for direct TLS
connection URLs. See the
[clnrest configuration reference](https://docs.corelightning.org/docs/rest#configuration).

The former c-lightning-REST data directory (default: `/var/lib/clightning-rest`)
and onion service keys (`/var/lib/tor/onion/clightning-rest`, if configured) are
retained. The backups service no longer includes the former data directory.
To keep backing it up, add its path to `services.backups.extraFiles`:

```nix
services.backups.extraFiles = [ "/var/lib/clightning-rest" ];
```

By default, clnrest's certificates and rune are stored in Core Lightning's network directory
and remain covered by the Core Lightning backup.

After migrating your configuration, set `nix-bitcoin.configVersion = "0.1.1";`.

### Upgrading to config version 0.1.2

bitcoind's RPC authentication cookie now lives at `/run/bitcoind/.cookie` for both
mainnet and regtest. The runtime directory allows the bitcoind service group to
read the cookie while preventing group members from replacing it.

Update external RPC clients and scripts that read `/var/lib/bitcoind/.cookie`
or `/var/lib/bitcoind/regtest/.cookie` to use `/run/bitcoind/.cookie`. If you set
`services.bitcoind.dataDir`, the old cookie was under that directory instead.
For clients running in containers or filesystem sandboxes, update any bind mounts
or allowed paths for cookie access as well.

The `bitcoin-cli` installed by bitcoinix reads the new path from `bitcoin.conf`
automatically. Services configured by bitcoinix use RPC credentials and need no
cookie path changes.

An old cookie can remain in the data directory after an unclean shutdown before
the upgrade. Once the upgraded bitcoind is running, that old cookie is stale and
can be removed. bitcoind creates a new cookie in `/run/bitcoind` each time it starts.

The mempool backend now listens on `services.mempool.address` (default
`127.0.0.1`) instead of all interfaces. With network namespace isolation enabled,
it listens on its namespace address. Access through the nginx frontend is
unchanged. If you access the backend API directly from another host, set
`services.mempool.address` to the node's LAN or VPN address.

The MariaDB server enabled by mempool now listens on `127.0.0.1` by default.
Mempool itself uses MariaDB's Unix socket and needs no connection changes. If
other clients access this database server over the network, explicitly set
`services.mysql.settings.mysqld.bind-address` to the desired listen address.
Existing explicit values of this option take precedence over the new default.

lnd now restarts automatically after a clean exit, so it can recover after its
chain backend health check shuts it down. By default, `lncli stop` also causes
lnd to restart after 10 seconds. To keep lnd stopped for maintenance, use
`sudo systemctl stop lnd` and update any scripts that relied on `lncli stop`
leaving it down. Start it again with `sudo systemctl start lnd` when maintenance
is complete.

BTCPay Server 2.4.5 blocks outbound requests to private network addresses by
default to prevent server-side request forgery. This affects webhooks, invoice
notification URLs and LNURL requests that point to localhost, LAN or VPN
addresses. The Lightning node that bitcoinix configures for BTCPay Server is
unaffected. To allow specific private destinations, list them in BTCPay's
`ssrfexceptions` setting:
```nix
systemd.services.btcpayserver.environment.BTCPAY_SSRFEXCEPTIONS = "192.168.1.50:8443;10.8.0.0/24";
```
Entries are exact hostnames, IP addresses or CIDR ranges, optionally with a port,
separated by `;` or `,`.

Keep each exception as narrow as possible: one address with its port, or the
smallest range that covers the destination. Never list the ports of node services
such as the lnd REST API or the bitcoind RPC. Anyone who can set a webhook, a
notification URL or a Lightning address in BTCPay can make it send requests to
every listed destination. A hostname entry trusts every address the hostname
resolves to, so list only hostnames whose DNS you control.

After updating any affected clients and settings, set
`nix-bitcoin.configVersion = "0.1.2";`.

### Upgrading to config version 0.1.3

Bitcoin Knots support and the `services.bitcoind.package` option have been removed.
Remove `services.bitcoind.package` from your configuration, including explicit
selections of Bitcoin Core. The daemon, `bitcoin-cli` and Core Lightning now use
`nix-bitcoin.pkgs.bitcoind` (Bitcoin Core) directly. `bitcoind-knots` is no longer
included in bitcoinix's pinned packages. If you used Knots, review any
Knots-specific settings in `services.bitcoind.extraConfig` before deploying
with Bitcoin Core.

electrs 0.12.0 switched to [bindex](https://github.com/romanz/bindex-rs), which uses
a new index format. electrs must rebuild its index from scratch, and it does not
convert or delete the old one, so bitcoinix refuses to start electrs while the old
index is in place. Reindexing takes from a few hours
to about a day, depending on your hardware. The final index is about 7% of the size
of bitcoind's `blocks/*.dat` files and can temporarily grow to about 14% during the
initial sync. electrs accepts connections while it indexes but answers with incomplete
history and balances until indexing has finished. The same applies to mempool if it
uses electrs as its Electrum server.

To upgrade, delete the old index before deploying (default data dir shown; for
regtest, the index is in `regtest` instead of `bitcoin`):
```bash
systemctl stop electrs
rm -r /var/lib/electrs/bitcoin
```
Then deploy the new system config to your node and follow the progress with
`journalctl -u electrs -f`.

If you roll back to the previous config after electrs 0.12 has started once, also
remove the marker file `/var/lib/electrs/bitcoin.bindex`. Otherwise the index check
is skipped on the next upgrade.

electrs 0.12.0 also requires Bitcoin Core 31 or later. It reads blocks through
bitcoind's REST interface, which bitcoinix enables automatically
(`services.bitcoind.rest.enable`). REST is served without
authentication on the RPC address and port: every source allowed by
`services.bitcoind.rpc.allowip` can read blocks, transactions, the UTXO set and the
mempool, bypassing RPC users and `rpcwhitelist`. If `services.bitcoind.rpc.allowip`
contains sources other than localhost and bitcoinix's network namespaces, evaluation
fails. Remove them, or set `services.bitcoind.rest.allowNonLocal = true` to accept
unauthenticated REST access for these sources. Evaluation also fails if
`services.bitcoind.extraConfig` contains `rpcallowip` or `includeconf` directives:
move RPC sources to `services.bitcoind.rpc.allowip`, or review the raw and included
settings and set `services.bitcoind.rest.allowUncheckedConfig = true`.
electrs no longer connects to bitcoind's whitelisted P2P port.

After migrating your configuration, set `nix-bitcoin.configVersion = "0.1.3";`.

# Customizing your configuration

## Get started with Nix

See [Nix - A One Pager](https://github.com/tazjin/nix-1p) for a short guide
to Nix, the language used in `configuration.nix`.\
You can follow along this guide by running command `nix repl` which allows you to interactively
evaluate Nix expressions.

For a general introduction to the Nix and NixOS ecosystem, see [nix.dev](https://nix.dev/).

## Set options

All features and services are configurable through options. You can find a list of
supported options at the top of each bitcoinix [module](https://github.com/bitcoinix/bitcoinix/blob/master/modules/modules.nix)
(Examples: [bitcoind.nix](https://github.com/bitcoinix/bitcoinix/blob/master/modules/bitcoind.nix), [btcpayserver.nix](https://github.com/bitcoinix/bitcoinix/blob/master/modules/btcpayserver.nix)).

Example: Set some `bitcoind` options by adding these lines to your `configuration.nix`:
```nix
# Use a custom data dir
services.bitcoind.dataDir = "/my/datadir";

# Enable txindex
services.bitcoind.txindex = true;
```

You can also use regular [NixOS options](https://search.nixos.org/options)
for configuring your system:
```nix
networking.hostName = "myhost";
time.timeZone = "UTC";
```

## Debug your configuration

To print the values of specific options of your config, add the following to your `configuration.nix`:
```nix
system.extraDependencies = let
  debugVal = config.networking.firewall.allowedTCPPorts;
  # More example options:
  # debugVal = config.environment.systemPackages;
  # debugVal = config.services.bitcoind.dataDir;
in lib.traceSeqN 3 debugVal [];
```
and run command `eval-config` from the deployment shell.

# Allowing external connections to services

## Allow peer connections to bitcoind

```nix
services.bitcoind = {
  # Accept incoming peer connections
  listen = true;

  # Listen to connections on all interfaces
  address = "0.0.0.0";

  # Set this to also add IPv6 connectivity.
  extraConfig = ''
    bind=::
  '';

  # If you're using the `secure-node.nix` template, set this to allow non-Tor connections
  # to bitcoind
  tor.enforce = false;
  # Also set this if bitcoind should not use Tor for outgoing peer connections
  tor.proxy = false;
};

# Open the p2p port in the firewall
networking.firewall.allowedTCPPorts = [ config.services.bitcoind.port ];
```

## Allow bitcoind RPC connections from LAN

Binding `0.0.0.0` with a wide `rpc.allowip` and an unscoped firewall rule
exposes RPC to every network the host is on. The public RPC whitelist limits
which methods a caller may use, not who can connect. Scope `rpc.allowip` and
the firewall rule to your LAN.

If the REST interface is enabled (`services.bitcoind.rest.enable`), it is served
on the RPC port without authentication. bitcoinix refuses to evaluate such a
config when `rpc.allowip` contains non-local sources,
unless you set `services.bitcoind.rest.allowNonLocal = true`.
The recognized loopback entries are `127.0.0.1`, `127.0.0.1/32`, `127.0.0.0/8`,
`::1` and `::1/128`. Use these spellings in `rpc.allowip` for local sources.

With REST enabled, raw `rpcallowip` and `includeconf` directives in
`services.bitcoind.extraConfig` are refused too, because their effective
allowlist can't be checked. Use `rpc.allowip` for checked sources, or review all
raw and included settings and set `services.bitcoind.rest.allowUncheckedConfig = true`.
This keeps the `rpc.allowip` check, unlike `allowNonLocal`.

```nix
services.bitcoind = {
  # Listen to RPC connections on all interfaces
  rpc.address = "0.0.0.0";

  # Allow RPC connections from external addresses
  rpc.allowip = [
    "10.10.0.0/24" # Allow a subnet
    "10.50.0.3" # Allow a specific address
  ];

  # Set this if you're using the `secure-node.nix` template
  tor.enforce = false;
};

# Open the RPC port in the firewall on the LAN interface only.
# Replace `eth0` with the name of your LAN interface.
networking.firewall.interfaces.eth0.allowedTCPPorts = [ config.services.bitcoind.rpc.port ];
```

## Allow connections to electrs

```nix
services.electrs = {
  # Listen to connections on all interfaces
  address = "0.0.0.0";

  # Set this if you're using the `secure-node.nix` template
  tor.enforce = false;
};

# Open the electrs port in the firewall
networking.firewall.allowedTCPPorts = [ config.services.electrs.port ];
```

You can use the same approach to allow connections to other services.

# Migrate existing services to bitcoinix

## Example: bitcoind

```shell
# 1. Stop bitcoind on your node
ssh root@nix-bitcoin-node 'systemctl stop bitcoind'
# Also stop bitcoind on the node that you'll be copying data from

# 2. Copy the data to the bitcoinix node
# Important: Add a trailing slash to the source path
rsync -a /path/to/existing/bitcoind-datadir/ root@nix-bitcoin-node:/var/lib/bitcoind

# 3. Fix data dir permissions on the bitcoinix node
ssh root@nix-bitcoin-node 'chown -R bitcoin: /var/lib/bitcoind'

# 4. Start bitcoind
ssh root@nix-bitcoin-node 'systemctl start bitcoind'
```

You can use the same workflow for other services.\
The default data dir path is `/var/lib/<service>` for all services.

Some services require extra steps:

- lnd

  Copy your wallet password to `$secretsDir/lnd-wallet-password` (See: [Secrets dir](#secrets-dir)).

- btcpayserver

  Copy the postgresql database:
  ```shell
  # Export (on the other node)
  sudo -u postgres pg_dump YOUR_BTCPAYSERVER_DB > export.sql
  # Restore (on the bitcoinix node)
  sudo -u postgres psql btcpaydb < export.sql
  ```

# Use bitcoind from another node

Here's how to use a bitcoind instance running on another node within a bitcoinix config:

```nix
imports = [ <nix-bitcoin/modules/presets/bitcoind-remote.nix> ];

services.bitcoind = {
  enable = true;

  # Address of the other node
  address = "10.10.0.2";
  rpc.address = "10.10.0.2";

  # Some bitcoinix services require whitelisted bitcoind p2p connections
  # to work reliably.
  # Search for `whitelistedPort` in this repo to see the affected services.
  # If you're using one of these services, either add a whitelisted p2p port
  # on your remote node via `whitebind` and set it here:
  whitelistedPort = <remote whitebind P2P port>;
  #
  # Or use the default p2p port and add `whitelist=<address of this node>` to
  # your remote bitcoind config:
  whitelistedPort = config.services.bitcoind.port;

  rpc.users = let
    # The fully privileged bitcoind RPC username of the other node
    privilegedName = "myrpcuser";
    # A restricted RPC user on the other node (see whitelist setup below)
    publicName = "mypublicrpcuser";
  in {
    privileged.name = privilegedName;
    public.name = publicName;
    ## Set this if you use btcpayserver. It needs its own restricted RPC user.
    # btcpayserver.name = "mybtcpayrpcuser";
  };
};
```

For each service that connects to bitcoind and has option
`services.<service>.tor.enforce` enabled (either explicitly or by importing
`secure-node.nix` or `enable-tor.nix`), you need to
allow the remote bitcoind connection:
```nix
systemd.services.<service>.serviceConfig.IPAddressAllow = [ config.services.bitcoind.rpc.address ];
```

> The above configuration is only required if the remote bitcoind **is
> not** accessed via Tor.

electrs reads blocks through bitcoind's REST interface. If you use electrs, set
`rest=1` on the other node (Bitcoin Core 31 or later). REST is unauthenticated and
available to every source allowed by the other node's `rpcallowip`, so keep that
list limited to the hosts that need it.


Services that only need the public RPC methods connect as `public`. Do not
use the privileged user for `public.name`: that gives every such service full
RPC access to the other node.

Create the RPC users on the other node with separate passwords, for example
using Bitcoin Core's `rpcauth`. For each restricted user, set
`rpcwhitelist=<username>:<comma-separated methods>` there using the evaluated
whitelist from your bitcoinix configuration:

- `mypublicrpcuser`: `services.bitcoind.rpc.users.public.rpcwhitelist`
- `mybtcpayrpcuser`, if used: `services.bitcoind.rpc.users.btcpayserver.rpcwhitelist`

Use [Debug your configuration](#debug-your-configuration) to inspect these options.
`modules/bitcoind-rpc-public-whitelist.nix` is only the base list: enabled services
extend it. For example, Core Lightning's bcli plugin adds `getblockfrompeer` and
mempool adds `gettxoutsetinfo`. BTCPay Server's whitelist also includes
`getblockfrompeer` and any permissions you explicitly grant it, such as
`scantxoutset` for wallet UTXO scanning. Update the remote whitelists when these
permissions change. The local settings do not configure the remote node.

When you add an `rpcwhitelist` for the public user on the other node, also set
`rpcwhitelistdefault=0` there. Otherwise Bitcoin Core gives every user without
a whitelist, including the privileged user, an empty whitelist.

Now save the RPC passwords to the following files on your bitcoinix node:
```shell
# Password of the privileged user (`privilegedName`)
$secretsDir/bitcoin-rpcpassword-privileged
# Password of the restricted user (`publicName`)
$secretsDir/bitcoin-rpcpassword-public

## Password of `mybtcpayrpcuser`, only needed when set in the above config snippet
# $secretsDir/bitcoin-rpcpassword-btcpayserver
```
See: [Secrets dir](#secrets-dir)

Afterwards, restart `bitcoind`: `systemctl restart bitcoind`.

# Temporarily disable a service

Sometimes you might want to disable a service without removing the service user and
integration with other services, as it would happen when setting
`services.<service>.enable = false`.

Use the following approach:
```
systemd.services.<service>.wantedBy = mkForce [];
```
This way, the systemd service still exists, but is not automatically started.\
Note: This only works for services that are not required by other active services.

# Appendix

## Secrets dir

The secrets dir is set by option `nix-bitcoin.secretsDir` and has the
following default values:

- If you're using the krops deployment method: `/var/src/secrets`

- Otherwise: `/etc/nix-bitcoin-secrets`
