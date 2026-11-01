# Managing your deployment

> [!NOTE]
> This document is inherited from nix-bitcoin, the predecessor project. It is a work in progress and may be outdated.

> [!WARNING]
> This documentation may be outdated or contain installation steps that do not work with
> bitcoinix yet.
> Please report problems at <https://github.com/bitcoinix/bitcoinix/issues>.

With a flake-based deployment, you deploy with `nixos-rebuild` or `colmena` as described in the
[installation guide](./install.md#4-deploy-with-a-flake).

## Deployment shell
This section applies to the legacy [krops deployment](./install.md#5-alternative-deploy-with-krops-legacy).
Run command `nix-shell` in your deployment directory.\
You now have access to deployment commands:

- `deploy`\
  Run `krops-deploy` and `eval-config` in parallel. If evaluation fails, the
  deployment is stopped.
- `krops-deploy`\
  Run `generate-secrets` and deploy your node with krops.
- `eval-config`\
  Locally evaluate the configuration. This is useful to check for configuration errors.
- `build-config`\
  Build your node system on your local machine.
- `generate-secrets`\
  Create the secrets required by your configuration in `./secrets/`.
- `update-nix-bitcoin`\
  Fetch and verify the latest signed bitcoinix release and pin it in
  `nix-bitcoin-release.nix`. See [Upgrading](./upgrading.md).
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

Snippets that use `config` or `lib`, like `config.services.bitcoind.port`, must be in a
module that takes these as arguments. The krops `configuration.nix` already does. The
Colmena example's `configuration.nix` takes only `config`; add `lib` there if you need it.
In the module of the `flake.nix` example, which is a plain attribute set, use this form instead:
```nix
({ config, lib, ... }: {
  networking.firewall.allowedTCPPorts = [ config.services.bitcoind.port ];
})
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

To print the values of options of your config, evaluate them on your computer.
With the `flake.nix` example, replace `fullnode` with the name of your node:
```shell
nix eval .#nixosConfigurations.fullnode.config.services.bitcoind.dataDir
nix eval --json .#nixosConfigurations.fullnode.config.networking.firewall.allowedTCPPorts
```

With Colmena, run from the `nix develop` shell:
```shell
colmena eval -E '{ nodes, ... }: nodes.fullnode.config.services.bitcoind.dataDir'
```

With krops, add the following to your `configuration.nix`:
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

  # Set this to also add IPv6 connectivity. This raw setting causes an evaluation
  # warning, see "Raw service configuration" above.
  extraConfig = ''
    bind=::
  '';

  # With the secure-node preset or `enable-tor.nix`, set this to allow non-Tor connections
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

  # Set this with the secure-node preset or `enable-tor.nix`
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

  # Set this with the secure-node preset or `enable-tor.nix`
  tor.enforce = false;
};

# Open the electrs port in the firewall
networking.firewall.allowedTCPPorts = [ config.services.electrs.port ];
```

You can use the same approach to allow connections to other services.

## Network namespace isolation

`nix-bitcoin.netns-isolation` is experimental and disabled by default; the secure-node
preset doesn't enable it. It runs each service listed in
[netns-isolation.nix](https://github.com/bitcoinix/bitcoinix/blob/master/modules/netns-isolation.nix)
in its own network namespace. With it enabled:

- The snippets above don't work. The module sets the listen addresses of these services
  (`address`, `rpc.address` and similar) to their namespace address in
  `169.254.<addressblock>.0/24`. Setting them yourself fails evaluation with
  `conflicting definition values`.
- A namespace accepts connections only from localhost, from the host and from the
  namespaces of connected services. Connections from your LAN are dropped, and opening
  ports in `networking.firewall` doesn't change this. Use onion services for remote access.
- With `tor.enforce`, a namespace also drops outgoing connections except to these
  addresses.
- IPv6 is disabled on the namespace interfaces.
- On the host, connect to a service at its namespace address,
  `config.nix-bitcoin.netns-isolation.netns.<service>.address`, not at `127.0.0.1`.
- It can't be combined with a [bitcoind on another node](#use-bitcoind-from-another-node),
  the WireGuard preset or firewalld. It needs the iptables firewall backend and a firewall
  package with `bin/iptables`. `networking.nftables` can stay enabled if you set
  `networking.firewall.backend = "iptables"` and `networking.firewall.package = pkgs.iptables`.

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
The data dir is set by option `services.<service>.dataDir`. For bitcoind, clightning,
lnd, electrs, fulcrum, rtl, btcpayserver and nbxplorer, it defaults to `/var/lib/<service>`.

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

Here's how to use a bitcoind instance running on another node within a bitcoinix config.
This doesn't work with [network namespace isolation](#network-namespace-isolation).

Import the `bitcoind-remote.nix` preset. With the `flake.nix` example, add it to the `modules` list in
`flake.nix`, next to `bitcoinix.nixosModules.default`:
```nix
(bitcoinix + "/modules/presets/bitcoind-remote.nix")
```
With Colmena, add `(inputs.bitcoinix + "/modules/presets/bitcoind-remote.nix")` to the
`imports` of your node. With krops, add it to `configuration.nix`:
```nix
imports = [ <nix-bitcoin/modules/presets/bitcoind-remote.nix> ];
```

Then configure the connection to the other node:
```nix
services.bitcoind = {
  enable = true;

  # Address of the other node
  address = "10.10.0.2";
  rpc.address = "10.10.0.2";

  # Only needed for BTCPay Server: NBXplorer needs a whitelisted P2P connection.
  # Set the port of a `whitebind` on the other node, or its regular P2P port
  # if it has `whitelist=<address of this node>`.
  whitelistedPort = 8333;

  rpc.users = {
    # The fully privileged RPC user on the other node
    privileged.name = "myrpcuser";
    # A restricted RPC user on the other node (see the whitelist setup below)
    public.name = "mypublicrpcuser";
    ## Set this if you use BTCPay Server. It needs its own restricted RPC user.
    # btcpayserver.name = "mybtcpayrpcuser";
  };
};

# With the secure-node preset or `enable-tor.nix`: don't create an onion service
# on this node that forwards to the other node.
nix-bitcoin.onionServices.bitcoind.enable = false;
```

With Tor enforcement (`services.<service>.tor.enforce`, enabled by the secure-node
preset and `enable-tor.nix`), services can't reach the other node. Allow the
connection for each service that connects to bitcoind, for example electrs:
```nix
systemd.services.electrs.serviceConfig.IPAddressAllow = [ "10.10.0.2" ];
```

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
# Password of the privileged user (`myrpcuser`)
$secretsDir/bitcoin-rpcpassword-privileged
# Password of the restricted user (`mypublicrpcuser`)
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
```nix
systemd.services.<service>.wantedBy = lib.mkForce [];
```
This needs `lib` in scope (see [Set options](#set-options)). The systemd service still
exists, but is not automatically started.\
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

Tools like agenix install secrets as symlinks to files outside the secrets directory
by default. `setup-secrets` can't set the owner and permissions of these files, so
setup fails. With agenix, set `symlink = false` for these secrets, and set their
`owner`, `group` and `mode` to the `user`, `group` and `permissions` of
`nix-bitcoin.secrets.<name>`. Or disable
`nix-bitcoin.generateSecrets` and `nix-bitcoin.setupSecrets`, set
`nix-bitcoin.secretsSetupMethod = "manual"`, and set the owners and permissions
declared in `nix-bitcoin.secrets` yourself.
