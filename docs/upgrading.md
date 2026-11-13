# Upgrading

Some releases contain changes that need manual action, such as a removed service, a
changed default or a required reindex. bitcoinix reports them when it evaluates your
configuration: if a change is newer than `nix-bitcoin.configVersion` and affects your
configuration, evaluation fails with a short description of the change. Options of
removed services fail evaluation regardless of the config version.

Keep `nix-bitcoin.configVersion` set in your configuration. If it is unset, these
changes are not reported.

When evaluation fails after an update, follow the sections below for each version
newer than your config version, starting with the oldest. Then set
`nix-bitcoin.configVersion` to the version named in the error message.

## Updating bitcoinix
Review the [release notes](./release-notes.md) for changes to packages and flake attributes.

With a [flake-based deployment](./install.md#4-deploy-with-a-flake), verify the new release tag as in
step 3 of the installation, set it in `flake.nix`, run `nix flake lock` and check the locked commit
as in step 4.2. Then deploy.

With krops, run `update-nix-bitcoin` from the [deployment shell](./configuration.md#deployment-shell).\
This fetches the latest release, verifies the signature on its release tag and updates `nix-bitcoin-release.nix`.\
It refuses to switch to a release older than the one currently pinned. To downgrade on purpose,
run `fetch-release.sh` with `releaseVersion=<version>` and write its output to `nix-bitcoin-release.nix`.

## Upgrading to config version 0.1.6

`services.lnd.lndconnect.onion` and
`services.clightning.plugins.clnrest.lnconnect.onion` now give the operator user
access to the `lnd-rest` and `clnrest` onion addresses only when
`nix-bitcoin.operator.enable` is set. This matches the access to the other onion
addresses. Before, the operator user received this access whenever it existed,
for example when `nix-bitcoin.operator.name` named an existing account and the
operator role was disabled. When the operator user didn't exist at all, the
`onion-addresses` service failed and published no onion address for anyone.

`lndconnect` isn't affected. It runs as the lnd user and reads the lnd user's copy
of the address. With the operator role disabled, only `lnconnect-clnrest` reads the
address from the operator user's directory. `nodeinfo` reads it too, but it enables
the operator role itself. So with `clnrest.lnconnect.onion` enabled, evaluation
fails unless the operator user has `clnrest` access. If you use it with the operator
role disabled, choose one of the following:

- Enable the operator role. It declares `users.users.<operator name>` as a normal
  user and merges into an existing declaration under that attribute, but also adds
  the operator's groups and its permission to run commands as service users. Don't
  use it if the account is declared under another attribute or comes from outside
  `users.users`, since NixOS would then manage it with its defaults:
  ```nix
  nix-bitcoin.operator.enable = true;
  ```
- Keep the role disabled and grant only the onion address access:
  ```nix
  nix-bitcoin.onionAddresses.access.<operator name> = [ "clnrest" ];
  ```
  `lnconnect-clnrest` also reads the admin rune, which only the `clightning` group
  can read. Without the role, run `lnconnect-clnrest` as root, or add the user to
  this group:
  ```nix
  users.users.<operator account>.extraGroups = [ "clightning" ];
  ```
  `<operator account>` is the `users.users` attribute that defines the account. It's
  usually the operator name.
  Members of this group can read the admin rune and use the clightning RPC socket,
  so they have full control over the node.
- If the operator account is disabled in `users.users`, enable it and use one of
  the options above. If it comes from outside `users.users`, for example from
  LDAP, and you can't declare it (see below), set `nix-bitcoin.operator.name` to
  an enabled account in `users.users` and use one of the options above for it, or
  disable `clnrest.lnconnect.onion`.

`nix-bitcoin.onionAddresses.access` now accepts only users that are defined and
enabled in `users.users`, and evaluation fails if it names any other user. Before,
it also accepted accounts created outside the configuration, for example with
`useradd` or via LDAP, because the `onion-addresses` service looked the names up
at runtime. For each such user, either remove it from
`nix-bitcoin.onionAddresses.access`, or declare the account in `users.users`.
NixOS then manages the account and applies its defaults to anything you leave out,
so declare its current settings: `isNormalUser` or `isSystemUser`, `uid`, the
primary `group` and its `users.groups` entry with the current `gid`,
`extraGroups`, `description`, `home`, `homeMode` and `shell`. With
`users.mutableUsers = false`, NixOS also manages the password, so declare it too
if the account uses one.

`setup-secrets` now fails when a declared secret file is empty or isn't a regular
file, as it does when one is missing. Then services can't read any secret until
setup succeeds.
Before deploying, check the [secrets dir](./configuration.md#secrets-dir) for
empty files, for example with `find /etc/nix-bitcoin-secrets -maxdepth 1 -type f -empty`:

- Write the secret to each empty file that a service needs. With
  `nix-bitcoin.generateSecrets = true`, setup regenerates empty passwords.
- Secret generation (`nix-bitcoin.generateSecrets = true`) doesn't replace an
  empty TLS key (`lnd-key`), WireGuard private key or replication SSH key, or a
  symlink to a missing file in their place, because a new key breaks the clients
  that trust the old one. Setup fails and names the file: restore it from a
  backup, or delete it to generate a new key.
- For a secret that may be empty, set `nix-bitcoin.secrets.<name>.allowEmpty = true`.
  bitcoinix sets it for `backup-encryption-env`.
- With the `bitcoind-remote.nix` preset and `nix-bitcoin.generateSecrets = false`,
  the local `bitcoin-HMAC-*` files are unused, but setup checks them too. Write
  the HMAC of the matching password to each one: the `<salt>$<hmac>` part of its
  `rpcauth=` line, as printed by Bitcoin Core's `share/rpcauth/rpcauth.py`. Or set
  `allowEmpty` for them.

lnd now stops with an error when `wallet.db` in lnd's network dir isn't a regular
file, for example a symlink to a moved or unmounted wallet. Before, lnd tried to
create a new wallet there. Restore the wallet, or remove the entry if lnd never ran
a wallet from it.

While lnd has no `wallet.db`, a symlink to a missing file at `lnd-seed-mnemonic` in
lnd's data dir now stops lnd with an error. An empty `lnd-seed-mnemonic`, which a
failed seed creation of an earlier version could leave, already stopped lnd with an
`lndinit` error. Now the error names the file. In both cases, if lnd never ran a
wallet from that seed, delete it, and lnd creates a new seed. Otherwise, restore it
from a backup.

lnd now creates its wallet in a temporary directory. Before, a failed wallet
creation could leave a partial `wallet.db`, and lnd then never started: every
start skipped wallet creation, and the lnd log shows an `lndinit` error such as
`private passphrase may not be empty`. If your node is stuck like this and lnd
never ran with this wallet, fix the cause, keep `lnd-seed-mnemonic` in lnd's
data dir, and move the partial wallet aside. lnd then creates the wallet from
the same seed. With the default data dir on mainnet:

```bash
systemctl stop lnd
mv /var/lib/lnd/chain/bitcoin/mainnet/wallet.db /var/lib/lnd/chain/bitcoin/mainnet/wallet.db.failed
systemctl start lnd
```

Each custom lnd macaroon (`services.lnd.macaroons`, also used by BTCPay Server and
charge-lnd) now has its own root key, with an ID from 7953919891889717248 to
7954201366866427903 (`0x6e62000000000000` to `0x6e62ffffffffffff`). Each time lnd
starts, bitcoinix deletes the root key of every ID in this range that no configured
macaroon uses. Before deploying, check that `lncli listmacaroonids` lists no ID in this
range. If it does, bake the macaroons that use such an ID again with an ID outside the
range.

bitcoinix now uses lnd's admin macaroon and gRPC each time lnd starts, also without
custom macaroons. Keep lnd's macaroons enabled: the `no-macaroons` option isn't
supported.

When lnd restarts during the deployment, bitcoinix creates the custom macaroons with
their new root keys. BTCPay Server and charge-lnd read their new macaroons without a
restart. Restart other services that read a custom macaroon only at startup; see
[Custom macaroons](./services.md#custom-macaroons). Copies of custom macaroons created
before this change use root key 0, like the admin macaroon, and stay valid. To revoke
them, see [Revoke all macaroons](./services.md#revoke-all-macaroons).

RTL is now bound to the units of its enabled backends, lnd for
`services.rtl.nodes.lnd` and clightning for `services.rtl.nodes.clightning`.
RTL sends the lnd admin macaroon and the clightning admin rune to their REST ports
without checking the certificate. So it now stops when a backend's unit stops,
crashes or exits, instead of polling the port of a stopped backend, which another
local user could take over. A backend's start starts RTL again once all of RTL's
backends run. Deploying this change restarts each backend that RTL uses once,
because its unit changes.

With both backends enabled:

- Stopping one backend, for example clightning for maintenance, also stops RTL for
  the other one.
- Starting RTL starts a stopped backend too. Leave RTL stopped until the maintenance
  is done. The backend's own start starts RTL again afterwards.

RTL now keeps the two-factor authentication (2FA) that you set up in its web
interface across restarts. Before, each restart turned 2FA off without a warning.
If you lose the authenticator, delete `RTL-Config.json` in RTL's data dir
(`/var/lib/rtl` by default) and restart RTL. `RTL-Config.json` holds the 2FA
secret and is now readable only by RTL's user. Before, members of group `rtl`
could read it too.

After migrating your configuration, set `nix-bitcoin.configVersion = "0.1.6";`.

## Upgrading to config version 0.1.5

Currencyrate, rebalance and mempool's `settings.CORE_RPC.PASSWORD` each
have a migration notice. Review the changes for each one you use before updating
your config version.

The Python currencyrate plugin has been replaced by Rust `cln-currencyrate`.
Keep `services.clightning.plugins.currencyrate.enable = true`, but update any
custom scripts before deploying:

- Replace `currencyrates <currency>` with `listcurrencyrates <currency>`.
  The response is now `{"currencyrates": [{"source": "…", "amount": 95000.0}, …]}`,
  with amounts in fiat per BTC, replacing the map of source names to msat per
  fiat unit. Adapt both parsing and units.
  `currencyrate <currency>` returns a single median rate in fiat per BTC.
- `currencyconvert` still takes `amount` and `currency`, for example
  `lightning-cli currencyconvert 10 USD`, but its `msat` result is now a JSON
  number rather than a string with an `msat` suffix. The median is now calculated
  from fiat prices before conversion.
- Rename `add-source` and `disable-source` in `services.clightning.extraConfig`
  to `currencyrate-add-source` and `currencyrate-disable-source`. Review them
  against the [new plugin's README](https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin).
  The plugin follows CLN's configured proxy.

After deploying, check that `lightning-cli help currencyconvert` and
`lightning-cli help listcurrencyrates` list the new RPCs. A live conversion such
as `lightning-cli currencyconvert 100 USD` also needs reachable price sources.

The rebalance plugin now uses Core Lightning's `askrene` routing. If you enable
`services.clightning.plugins.rebalance.enable`, update custom scripts and
configuration before deploying:

- Remove the `getroute_method` argument from `rebalance` RPC calls; it is no
  longer accepted.
- Remove `rebalance-getroute`, `rebalance-maxhops` and `rebalance-msatfactor` from
  `services.clightning.extraConfig` and any included configuration files. These
  settings are still accepted with a deprecation warning but are ignored, so they
  no longer control route selection or hop limits.
- Update scripts that read `rebalancereport`: its `getroute_method`,
  `maxhops_threshold` and `msatfactor` fields have been removed.

mempool no longer accepts `services.mempool.settings.CORE_RPC.PASSWORD`. Its
settings are copied to the world-readable Nix store, so evaluation now fails when
this option is set. Remove it and save the password to `bitcoin-rpcpassword-public`
in the [secrets dir](./configuration.md#secrets-dir). mempool reads it from there
at startup, also when it uses
[bitcoind from another node](./configuration.md#use-bitcoind-from-another-node).
The old value stays readable in the Nix store until it is garbage-collected, so
change the password if untrusted users or services run on the node.

After addressing these changes, set `nix-bitcoin.configVersion = "0.1.5";`.

## Upgrading to config version 0.1.3

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
systemctl stop electrs && rm -r /var/lib/electrs/bitcoin
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

Services using `nix-bitcoin.lib.defaultHardening`, including Bitcoin Core, Core
Lightning and LND, now see `/run` and `/dev` (including `/dev/shm`) as read-only.
Before deploying, review custom service hooks (`preStart`, `postStart`,
`ExecStartPre`, `ExecStartPost`) and plugins that write there: they can now fail
with `Read-only file system`.

The service's `RuntimeDirectory`, `StateDirectory`, configured data directory
and existing `ReadWritePaths` remain writable. Move custom writes into those
directories, or add a narrow `ReadWritePaths` exception for an existing path
that must remain writable. See
[Write to /run or /dev/shm from a service hook](./configuration.md#write-to-run-or-devshm-from-a-service-hook)
for an example. If you have no custom code writing outside the allowed
directories, no script changes are needed.

mempool 3.3 migrates its MariaDB database from schema version 97 to 106 on the
first start of the backend. The migration can't be undone: rolling back the
NixOS generation keeps the migrated database, and mempool 3.2 has no downgrade
path. The database is not covered by `services.backups`. To keep a way back,
dump it before deploying:
```bash
mysqldump --single-transaction mempool > mempool-3.2.sql
```
Run this as root, and replace `mempool` if you set `services.mempool.database.name`.

`setup-secrets` now runs in a sandbox whenever `nix-bitcoin.setupSecrets` is
enabled, including when `nix-bitcoin.generateSecrets` enables it automatically.
Before deploying:

- Replace declared secret symlinks to files outside `nix-bitcoin.secretsDir`
  with files inside that directory, preserving their contents. If another tool
  supplies or rotates these secrets, configure it to install the files there
  before `setup-secrets` starts. External targets are read-only or hidden inside
  the sandbox.
- Review custom `nix-bitcoin.generateSecretsCmds`. They have no IP network access
  and can write only to the secrets directory and private temporary directories.
  Put final secret files in the secrets directory. Commands requiring writable
  executable memory (such as JIT compilation) or setuid/setgid file modes are
  blocked. If generation needs these facilities, arrange to supply all required
  secrets before `setup-secrets`, set `nix-bitcoin.generateSecrets = false`, and
  keep `nix-bitcoin.setupSecrets = true` to set the supplied files' permissions.
- Remove setuid/setgid bits from any `nix-bitcoin.secrets.<name>.permissions`
  values; the sandbox rejects those modes when setting permissions too.

The secrets directory is now `root:root 0700` while setup runs even when
`generateSecrets` is false. If any step fails, every service loses access to
secrets in that directory until setup succeeds. After fixing the cause reported
by `journalctl -u setup-secrets`, run as root:

```bash
systemctl reset-failed setup-secrets
systemctl restart setup-secrets
systemctl start nix-bitcoin-secrets.target
```

Then restart any dependent services that failed. Successful setup restores the
directory to `0751` and applies each declared secret's configured owner and mode.

After migrating your configuration, set `nix-bitcoin.configVersion = "0.1.3";`.

## Upgrading to config version 0.1.2

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
mempool itself uses MariaDB's Unix socket and needs no connection changes. If
other clients access this database server over the network, explicitly set
`services.mysql.settings.mysqld.bind-address` to the desired listen address.
Existing explicit values of this option take precedence over the new default.

LND now restarts automatically after a clean exit, so it can recover after its
chain backend health check shuts it down. By default, `lncli stop` also causes
LND to restart after 10 seconds. To keep LND stopped for maintenance, use
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
such as the LND REST API or the bitcoind RPC. Anyone who can set a webhook, a
notification URL or a Lightning address in BTCPay can make it send requests to
every listed destination. A hostname entry trusts every address the hostname
resolves to, so list only hostnames whose DNS you control.

After updating any affected clients and settings, set
`nix-bitcoin.configVersion = "0.1.2";`.

## Upgrading to config version 0.1.1

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
since JoinMarket was removed, so it rejected every namespace. To run a command in a
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
grant also allowed sending payments and abandoning channels. LND regenerates
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
