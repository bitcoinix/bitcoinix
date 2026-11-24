# Managing your deployment

With a flake-based deployment, you deploy with `nixos-rebuild` or `colmena` as described in the
[installation guide](./install.md#4-deploy-with-a-flake).

## Bitcoin network

> [!WARNING]
> Use a separate deployment for each Bitcoin network. If you change
> `services.bitcoind.network` on an existing node, Bitcoin Core, Core Lightning
> and electrs switch to the selected network's data directories. Fulcrum,
> Mempool, BTCPay Server and NBXplorer still open their existing databases.
> For example, switching a mainnet BTCPay node to signet leaves its mainnet
> stores and extended public keys (xpubs) in the database used on signet.

The deployment defaults to mainnet. To run a node on signet, set

```nix
services.bitcoind.network = "signet";
```

| Network | Use | Bitcoin P2P port | Bitcoin RPC port |
| --- | --- | ---: | ---: |
| `"mainnet"` | Production | 8333 | 8332 |
| `"signet"` | Public signet | 38333 | 38332 |
| `"testnet4"` | Public proof-of-work test network | 48333 | 48332 |
| `"regtest"` | Local regression tests | 18444 | 18443 |

Core Lightning, electrs, Fulcrum, Unbeholden Wallet, Mempool and BTCPay Server
can use either public test network. Mempool serves the selected network at `/`.
With the packaged software, these combinations fail at evaluation time.

- **LND on signet or testnet4.** Its wallet initializer, `lndinit`, cannot
  create wallets for these networks. This also applies when another service
  enables LND, such as charge-lnd or BTCPay Server with the LND backend.
- **CLBOSS or Trustedcoin on testnet4.** Both Core Lightning plugins support signet.

BTCPay Server defaults to a testnet3 block explorer on testnet4. Sign in as a
server administrator, open **Server Settings → Policies → Block Explorers**, set
`BTC-CHAIN` to `https://mempool.space/testnet4/tx/{0}`, and save the policy.

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
- `fetch-release`\
  Fetch and verify the latest signed bitcoinix release and print its pin without
  writing it. `update-nix-bitcoin` uses it.
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

To give a LAN client its own RPC user, add it to `services.bitcoind.rpc.users`:
```nix
services.bitcoind.rpc.users.alice = {
  # The part after `rpcauth=alice:` in the output of
  # Bitcoin Core's `share/rpcauth/rpcauth.py alice`
  passwordHMAC = "<salt>$<hmac>";
  # The RPC methods that alice may call. Without this, alice may call all methods.
  rpcwhitelist = [ "getblockchaininfo" "getblock" ];
};
```
`passwordHMAC` is written to the world-readable Nix store, like `rpcauth` lines in
`services.bitcoind.extraConfig`. Any local user can read it and test password
guesses offline. So use a long random password, like the one that `rpcauth.py`
generates when you don't pass a password. If an RPC user has a weak password,
change it. The old HMAC stays readable in the Nix store until it is garbage-collected.

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
in its own network namespace. This separates the services from each other and from the
outside network. It doesn't separate them from processes in the host network namespace,
and services without `tor.enforce` can reach your LAN. With it enabled:

- The snippets above don't work. The module sets the listen addresses of these services
  (`address`, `rpc.address` and similar) to their namespace address in
  `169.254.<addressblock>.0/24`. Setting them yourself fails evaluation with
  `conflicting definition values`.
- A namespace accepts connections only from its own localhost, from the namespaces of
  connected services and from the host. Connections from the host come from the bridge
  address `169.254.<addressblock>.10`, which every namespace accepts. This covers every
  process in the host network namespace, not only the operator user: Tor, sshd, backup
  jobs and services without a namespace can reach every service listener, so the services
  still rely on their own authentication.
- Connections from your LAN are dropped, and opening ports in `networking.firewall`
  doesn't change this. Use onion services for remote access.
- Outgoing connections leave through the host with NAT, and the host doesn't filter
  forwarded traffic. A service without `tor.enforce` can connect to other hosts in your
  LAN, not only to the internet.
- With `tor.enforce`, a namespace drops outgoing connections except to the addresses it
  accepts connections from.
- IPv6 is disabled on the namespace interfaces.
- Each namespace copies the host's `net.mptcp.enabled` setting when it is created.
  A later change of the host setting doesn't reach existing namespaces, and a switch
  that only changes this setting doesn't recreate them. Reboot after you change this setting.
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
ssh root@<node> 'systemctl stop bitcoind'
# Also stop bitcoind on the node that you'll be copying data from

# 2. Copy the data to the bitcoinix node
# Important: Add a trailing slash to the source path
rsync -a /path/to/existing/bitcoind-datadir/ root@<node>:/var/lib/bitcoind

# 3. Fix data dir permissions on the bitcoinix node
ssh root@<node> 'chown -R bitcoin: /var/lib/bitcoind && chmod 750 /var/lib/bitcoind'

# 4. Start bitcoind
ssh root@<node> 'systemctl start bitcoind'
```

You can use the same workflow for other services.\
The data dir is set by option `services.<service>.dataDir`. For bitcoind, clightning,
lnd, electrs, fulcrum, rtl, thunderhub, btcpayserver and nbxplorer, it defaults to `/var/lib/<service>`.

Some services require extra steps:

- LND

  Copy your wallet password to `$secretsDir/lnd-wallet-password` (See: [Secrets dir](#secrets-dir)).

  When lnd on the bitcoinix node starts without a wallet, as after the first deploy, it
  creates a new wallet and writes its seed to `lnd-seed-mnemonic` in its data dir
  (`/var/lib/lnd` by default). This seed can't recover your migrated wallet. `rsync -a`
  keeps files that the old data dir doesn't have, so the file would stay. Before you copy
  the data, copy the file off the node and remove it from the node. Keep that copy if you
  sent funds to the new wallet, because the migration replaces that wallet:
  ```shell
  scp root@<node>:/var/lib/lnd/lnd-seed-mnemonic ./new-wallet-seed
  ssh root@<node> 'rm /var/lib/lnd/lnd-seed-mnemonic'
  ```
  The seed of your migrated wallet is the seed of your old node. If the old data dir has
  an `lnd-seed-mnemonic`, the copy brings it over.

  If you migrated lnd before, the `lnd-seed-mnemonic` on the node holds your old node's
  seed only if the old data dir had that file. Otherwise it holds the seed of the wallet
  that bitcoinix created before the copy, and it can't recover your migrated wallet. Keep
  your old node's seed as the backup of your wallet.

- BTCPay Server

  Copy the PostgreSQL database:
  ```shell
  # Export (on the other node)
  sudo -u postgres pg_dump YOUR_BTCPAYSERVER_DB > export.sql
  # Restore (on the bitcoinix node)
  sudo -u postgres psql btcpaydb < export.sql
  ```
  This doesn't copy the private keys of hot wallets. NBXplorer stores them in its own
  database (`nbxplorer` on bitcoinix). Without them, hot wallets come back watch-only.
  Before you migrate, make sure you have the recovery phrase of each hot wallet, so you
  can import it again in BTCPay Server.

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
    ## Core Lightning, mempool and BTCPay Server each need their own restricted
    ## RPC user. Set the ones for the services you use.
    # clightning.name = "myclightningrpcuser";
    # mempool.name = "mymempoolrpcuser";
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
These services resolve names in-process from `/etc/hosts`, so a host name that isn't
there won't resolve. Set `address` to an IP address, or add the name of the other node
to `networking.hosts`.

electrs reads blocks through bitcoind's REST interface. If you use electrs, set
`rest=1` on the other node (Bitcoin Core 31 or later). REST is unauthenticated and
available to every source allowed by the other node's `rpcallowip`, so keep that
list limited to the hosts that need it.


Services that only need the public RPC methods connect as `public`. Do not
use the privileged user for `public.name`: that gives every such service full
RPC access to the other node. Core Lightning, mempool and BTCPay Server connect
as their own users, so that the methods only they need don't reach the other
services.

Create the RPC users on the other node with separate passwords, for example
using Bitcoin Core's `rpcauth`. For each restricted user, set
`rpcwhitelist=<username>:<comma-separated methods>` there using the evaluated
whitelist from your bitcoinix configuration:

- `mypublicrpcuser`: `services.bitcoind.rpc.users.public.rpcwhitelist`
- `myclightningrpcuser`, if used: `services.bitcoind.rpc.users.clightning.rpcwhitelist`
- `mymempoolrpcuser`, if used: `services.bitcoind.rpc.users.mempool.rpcwhitelist`
- `mybtcpayrpcuser`, if used: `services.bitcoind.rpc.users.btcpayserver.rpcwhitelist`

Use [Debug your configuration](#debug-your-configuration) to inspect these options.
`modules/bitcoind-rpc-public-whitelist.nix` is the base list of the public user.
The other restricted users add the methods that their service needs:
`getblockfrompeer` for Core Lightning's bcli plugin and for BTCPay Server, and
`gettxoutsetinfo` for mempool. BTCPay Server's whitelist also includes any
permissions you explicitly grant it, such as `scantxoutset` for wallet UTXO
scanning. Update the remote whitelists when these permissions change. The local
settings do not configure the remote node.

When you add an `rpcwhitelist` for the public user on the other node, also set
`rpcwhitelistdefault=0` there. Otherwise Bitcoin Core gives every user without
a whitelist, including the privileged user, an empty whitelist.

Now save the RPC passwords to the following files on your bitcoinix node:
```shell
# Password of the privileged user (`myrpcuser`)
$secretsDir/bitcoin-rpcpassword-privileged
# Password of the restricted user (`mypublicrpcuser`)
$secretsDir/bitcoin-rpcpassword-public

## Passwords of the users for Core Lightning, mempool and BTCPay Server,
## only needed for the services you use
# $secretsDir/bitcoin-rpcpassword-clightning
# $secretsDir/bitcoin-rpcpassword-mempool
# $secretsDir/bitcoin-rpcpassword-btcpayserver
```
Without `nix-bitcoin.generateSecrets`, `nix-bitcoin.setupSecrets` also checks a
`bitcoin-HMAC-<user>` file for each of these users. This node doesn't use them, so
create them empty and set `nix-bitcoin.secrets.bitcoin-HMAC-<user>.allowEmpty = true`,
or write the HMAC of each password: the part after `rpcauth=<username>:` in the
line that Bitcoin Core's `share/rpcauth/rpcauth.py` prints.
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
owners and permissions and restricts undeclared files to root. A declared secret
that is missing or isn't a regular file fails setup, and so does an empty one,
unless its `nix-bitcoin.secrets.<name>.allowEmpty` is set. `setup-secrets` makes the
directory accessible only to root while it runs; if setup fails, services lose
access to all secrets there until a successful run restores directory mode `0751`.

`nix-bitcoin.generateSecrets = true` enables setup and generates secrets in the
same sandbox. Custom `nix-bitcoin.generateSecretsCmds` have no IP network access
and can write only to the secrets directory and private temporary directories.
Store final secrets inside the secrets directory, including secrets supplied by
another tool, rather than linking to external files. See the
[0.1.3 upgrade instructions](./upgrading/0.1.3.md)
for migration and recovery steps.

Tools like agenix install secrets as symlinks to files outside the secrets directory
by default. `setup-secrets` can't set the owner and permissions of these files, so
setup fails. With agenix, set `symlink = false` for these secrets, and set their
`owner`, `group` and `mode` to the `user`, `group` and `permissions` of
`nix-bitcoin.secrets.<name>`. Or disable
`nix-bitcoin.generateSecrets` and `nix-bitcoin.setupSecrets`, set
`nix-bitcoin.secretsSetupMethod = "manual"`, and set the owners and permissions
declared in `nix-bitcoin.secrets` yourself.
