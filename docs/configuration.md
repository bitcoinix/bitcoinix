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

After migrating your configuration, set `nix-bitcoin.configVersion = "0.1.1";`.

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

```nix
services.bitcoind = {
  # Listen to RPC connections on all interfaces
  rpc.address = "0.0.0.0";

  # Allow RPC connections from external addresses
  rpc.allowip = [
    "10.10.0.0/24" # Allow a subnet
    "10.50.0.3" # Allow a specific address
    "0.0.0.0/0" # Allow all addresses
  ];

  # Set this if you're using the `secure-node.nix` template
  tor.enforce = false;
};

# Open the RPC port in the firewall
networking.firewall.allowedTCPPorts = [ config.services.bitcoind.rpc.port ];
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
    name = "myrpcuser";
  in {
    privileged.name = name;
    public.name = name;
    ## Set this if you use btcpayserver
    # btcpayserver.name = name;
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


Now save the password of the RPC user to the following files on your bitcoinix node:
```shell
$secretsDir/bitcoin-rpcpassword-privileged
$secretsDir/bitcoin-rpcpassword-public

## Only needed when set in the above config snippet
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
