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
See [Upgrading](./upgrading.md) for how to update bitcoinix and for the changes that
need manual action in each release.

# Customizing your configuration

## Get started with Nix

See [Nix - A One Pager](https://github.com/tazjin/nix-1p) for a short guide
to Nix, the language used in `configuration.nix`.\
You can follow along with this guide by running command `nix repl` which allows you to interactively
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

## Raw service configuration (`extraConfig`)

Prefer dedicated NixOS options when available. Settings you supply through
`extraConfig` are unsupported by bitcoinix. You take full responsibility for
checking their correctness, security and compatibility with the generated
configuration, including after upgrades. This also covers files loaded through
raw settings such as Bitcoin Core's `includeconf`.

Raw settings may override managed settings or bypass security checks. For example,
putting `rest=1` in `services.bitcoind.extraConfig` does not enable the checks
controlled by `services.bitcoind.rest.enable`. Successful evaluation does not
validate the resulting service configuration.

Non-empty `extraConfig` on an enabled service produces a NixOS evaluation warning.
Presets and plugins may populate it too; the responsibility notice applies to
settings you add yourself. The warning does not print the configuration contents.

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

# Open the P2P port in the firewall
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

- LND

  Copy your wallet password to `$secretsDir/lnd-wallet-password` (See: [Secrets dir](#secrets-dir)).

- BTCPay Server

  Copy the PostgreSQL database:
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

  # Some bitcoinix services require whitelisted bitcoind P2P connections
  # to work reliably.
  # Search for `whitelistedPort` in this repo to see the affected services.
  # If you're using one of these services, either add a whitelisted P2P port
  # on your remote node via `whitebind` and set it here:
  whitelistedPort = <remote whitebind P2P port>;
  #
  # Or use the default P2P port and add `whitelist=<address of this node>` to
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
    ## Set this if you use BTCPay Server. It needs its own restricted RPC user.
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

# Write to /run or /dev/shm from a service hook

Most bitcoinix services (those that use `nix-bitcoin.lib.defaultHardening`, like
`bitcoind`, `clightning` and `lnd`) see `/run` and `/dev` as read-only.
A custom `preStart`, `postStart` or `ExecStartPost` command in these services that
writes there fails with `Read-only file system`.
The service's own `RuntimeDirectory` (e.g. `/run/lnd`) and data dir stay writable,
and so do device nodes like `/dev/null`.

To allow writing to another path, add it to `ReadWritePaths`. The path must exist
when the service starts:
```nix
systemd.services.lnd.serviceConfig.ReadWritePaths = [ "/run/my-dir" ];
```
This adds to the service's own `ReadWritePaths`; it doesn't replace them.\
Alternatively, prefix a command in `ExecStartPre` or `ExecStartPost` with `+` to run
it as root outside the sandbox.

# Appendix

## Secrets dir

The secrets dir is set by option `nix-bitcoin.secretsDir` and has the
following default values:

- If you're using the krops deployment method: `/var/src/secrets`

- Otherwise: `/etc/nix-bitcoin-secrets`

With `nix-bitcoin.setupSecrets = true`, `setup-secrets` sets the declared secrets'
owners and permissions and restricts undeclared files to root. It makes the
directory accessible only to root while it runs; if setup fails, services lose
access to all secrets there until a successful run restores directory mode `0751`.

`nix-bitcoin.generateSecrets = true` enables setup and generates secrets in the
same sandbox. Custom `nix-bitcoin.generateSecretsCmds` have no IP network access
and can write only to the secrets directory and private temporary directories.
Store final secrets inside the secrets directory, including secrets supplied by
another tool, rather than linking to external files. See the
[0.1.3 upgrade instructions](./upgrading.md#upgrading-to-config-version-013)
for migration and recovery steps.
