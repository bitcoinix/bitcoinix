# Using services

How to reach and run the services on your node. Most sections assume the
`secure-node.nix` preset, which adds Tor onion services, `nodeinfo` and the `operator`
user.

## Node administration

### Nodeinfo
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
`nix-bitcoin.revision` yourself in that case.

The revision is baked into the `nodeinfo` script, so every bitcoinix update produces a
new system generation and boot entry, even when no package changed; no service restarts.
Set `nix-bitcoin.revision = null;` to opt out.

The entries of bitcoind, clightning, lnd, electrs, fulcrum, btcpayserver, rtl and mempool
include the `version` of the package the service runs.

Without arguments `nodeinfo` prints all entries. Arguments change that:
```shell
nodeinfo --version           # print only the bitcoinix revision, as a JSON string
nodeinfo bitcoind lnd        # print only these entries
```
See `nodeinfo --help`.

`nodeinfo` and `jq` are included in the `secure-node.nix` preset. Without the preset,
set `nix-bitcoin.nodeinfo.enable = true` and install `jq` for the example above.

#### Troubleshoot onion addresses

The `onion-addresses` service only publishes valid Tor v3 onion addresses. If a
hostname file is unreadable, contains invalid content, or takes more than 10 seconds
to read, its address is omitted. Other valid addresses are still published, but
`onion-addresses.service` reports failure. `nodeinfo` then prints only
`error: service 'onion-addresses' is not running`.

Run `journalctl -u onion-addresses` to identify the affected
`/var/lib/tor/onion/<service>/hostname` file. It must be readable by the `tor` user
and contain a single v3 onion address, with at most one trailing newline. Once the
Tor-generated hostname file and its permissions are correct, run
`systemctl restart onion-addresses` as root, then retry `nodeinfo`.

### Managing services

NixOS uses the [systemd](https://wiki.archlinux.org/title/systemd) service manager.

Usage:
```shell
# Show service status
systemctl status bitcoind

# Show the last 100 log messages
journalctl -u bitcoind -n 100
# Show all log messages since the last system boot
journalctl -b -u bitcoind

# These commands require root permissions
systemctl stop bitcoind
systemctl start bitcoind
systemctl restart bitcoind

# Show the service definition
systemctl cat bitcoind
# Show all service parameters
systemctl show bitcoind
```

### Connect to bitcoinix node through the SSH onion service
The `secure-node.nix` preset adds an onion service for SSH. It lets you reach and deploy
to your node through Tor, e.g. when it's behind NAT. It uses the SSH keys that you
already deploy with. By default, the preset turns off SSH password login
(`services.openssh.settings.PasswordAuthentication` and `KbdInteractiveAuthentication`),
so sshd accepts only keys, also over the node's IP address.

1. Get the SSH onion address (excluding the port suffix)

    ```
    ssh operator@bitcoin-node
    nodeinfo | jq -r .sshd.onion_address | sed 's/:.*//'
    ```

2. On your local machine, run Tor (listening on its default SOCKS port 9050) and
   install an OpenBSD-style `nc`, e.g. `netcat` from nixpkgs or `netcat-openbsd` on
   Debian. Add a host alias to `~/.ssh/config`:

    ```
    Host bitcoin-node-onion
      HostName <SSH onion address>
      User root
      ProxyCommand nc -X 5 -x 127.0.0.1:9050 %h %p
    ```

3. Connect with `ssh bitcoin-node-onion`.

4. To deploy through Tor, use `bitcoin-node-onion` as the node's address in your
   deployment tool, e.g. `nixos-rebuild --target-host bitcoin-node-onion`, Colmena's
   `deployment.targetHost` or krops' `target`. All of them connect through `ssh`, so
   they use the alias.

#### Keep the node's IP address private

The onion service and your node's IP address reach the same sshd, with the same host
keys. Internet scanners index SSH host keys by IP address, so anyone who learns the
onion address can look up its host key and find your node's IP address. To keep them
apart, don't expose SSH to the internet:

- First switch your deployment to the onion alias (step 4), also `--build-host` if it
  points to the node, and check that a deploy works. New SSH connections to the IP
  address fail once the port is closed.
- Set `services.openssh.openFirewall = false`, and remove any other firewall rule that
  opens the SSH port to the internet. To keep SSH over a VPN, open the port on that
  interface, e.g. `networking.firewall.interfaces.wg0.allowedTCPPorts = [ 22 ];`.
- Before you deploy the firewall change, open a root SSH session over the IP address.
  Keep it open until a new root login through the onion service works, and keep
  console access in case Tor fails on the node.

Or let only your own Tor client reach the onion service with
[client authorization](https://community.torproject.org/onion-services/advanced/client-auth/)
(`services.tor.relay.onionServices.sshd.authorizedClients`).

### Backups

`services.backups` backs up node data with duplicity, to `/var/lib/localBackups` by
default. See the Backups section in
[`examples/configuration.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/examples/configuration.nix)
and the [module](https://github.com/bitcoinix/bitcoinix/blob/master/modules/backups.nix)
for the options.

The backup includes the data directories of bitcoind, lnd, Core Lightning, NBXplorer
and BTCPay Server, dumps of the BTCPay Server databases, `/var/lib/tor`,
`/var/lib/nixos` and, with `nix-bitcoin.generateSecrets`, the secrets directory.
It leaves out the blockchain and its indexes, unless `with-bulk-data` is set.

#### Lightning channel databases

The backup never includes lnd's `graph` directory, which holds `channel.db`, or
Core Lightning's `lightningd.sqlite3` and the SQLite files that
`services.clightning.wallet` sets. The daemons write these files while the backup
runs, so a copy can be torn. A copy is also outdated as soon as a channel changes.
A node that runs from an outdated channel database can broadcast a revoked channel
state, and the peer can then take all funds in that channel. Never restore a copied
channel database. Backups made before bitcoinix 0.2.0 contain them.

To recover Lightning funds, use these files from the backup instead. Both ways ask
each peer to force close its channel, so they need the peer to be reachable. They
get back settled funds, but not funds in pending payments.

- lnd: the seed `/var/lib/lnd/lnd-seed-mnemonic` and the static channel backup
  `/var/lib/lnd/chain/bitcoin/mainnet/channel.backup`.
  Restore the seed on a node where lnd hasn't created a wallet yet, and bitcoinix
  creates the wallet from it. Keep the restored `channel.backup` outside lnd's data
  directory, because lnd replaces its own copy with the channels it knows. Then run
  `lncli restorechanbackup --multi_file <path to channel.backup>`. See lnd's
  [recovery guide](https://github.com/lightningnetwork/lnd/blob/master/docs/recovery.md),
  also for recovering on-chain funds.
- Core Lightning: `hsm_secret` and `emergency.recover` in `/var/lib/clightning/bitcoin/`.
  Restore both to that directory, owned by the `clightning` user, before Core Lightning
  first starts on the node. Then run `lightning-cli emergencyrecover`. See Core
  Lightning's [recovery guide](https://docs.corelightning.org/docs/recovery).

For a copy of the Core Lightning database that's always current, use
[database replication](#core-lightning-database-replication). When Core Lightning
stores its database in PostgreSQL, don't add it to
`services.backups.postgresqlDatabases`. Its dump is an outdated copy of the channel
state too.

#### bitcoind wallets

Before each backup, the `bitcoind-wallet-backup` unit asks bitcoind for a consistent
copy of each loaded wallet. It writes them to `/var/lib/bitcoind/wallet-backups`
as `wallet-<sha256 of the wallet name>.dat`, and `wallet-names.json` there maps each
file to its wallet name. bitcoinix manages this directory and replaces the copies
before each backup, so don't keep other files there. The backup also has the wallet
files themselves, but a copy of a loaded wallet's file can be torn. Restore a loaded
wallet from its copy, for example with `bitcoin-cli restorewallet <name> <copy>`.

When bitcoind doesn't run during a backup, there are no copies, and the wallet files
are consistent. If a copy fails, or bitcoind is starting or stopping, the `duplicity`
unit fails after the backup. With the `bitcoind-remote.nix` preset, the wallets are
on the other node, and the backup makes no copies.

## Wallets and apps

### Connect to electrs
Electrum wallets can connect to your electrs (or Fulcrum) server through its onion
service, which the `secure-node.nix` and `enable-tor.nix` presets create.

<a id="requirements-android"></a>

#### Android requirements
* [Orbot](https://guardianproject.info/apps/org.torproject.android/) from F-Droid or [Google Play](https://play.google.com/store/apps/details?id=org.torproject.android)
* [Electrum](https://electrum.org/#download) from the direct download or [Google Play](https://play.google.com/store/apps/details?id=org.electrum.electrum)

<a id="requirements-desktop"></a>

#### Desktop requirements
* [Tor](https://support.torproject.org/little-t-tor/), listening on its default SOCKS port 9050
* [Electrum](https://electrum.org/#download)

#### Connect your wallet

1. Enable electrs in your configuration:
    ```nix
    services.electrs.enable = true;
    ```
    For Fulcrum, set `services.fulcrum.enable = true` and use `.fulcrum` instead of
    `.electrs` below.

2. Deploy your configuration.

3. Get the electrs onion address, in the format `<onion-address>:<port>`:
    ```
    nodeinfo | jq -r .electrs.onion_address
    ```

4. Connect to electrs

    Make sure Tor is running on your desktop or as Orbot on Android.

    On your desktop
    ```
    electrum --oneserver -s "<electrs onion address>:t" -p socks5:127.0.0.1:9050
    ```

    On Android, open the network settings and set:
    - Proxy: SOCKS5, host `127.0.0.1`, port `9050`
    - Auto-connect: off, one-server mode: on
    - Server: `<electrs onion address>:t`

### Connect to RTL
RTL listens on localhost by default. Connect to it through an SSH tunnel, then open
`http://localhost:3000` in your browser:

```
ssh -L 3000:127.0.0.1:3000 operator@bitcoin-node
```

With `netns-isolation`, RTL listens in its own network namespace. Use the address from
`nodeinfo | jq -r .rtl.local_address` instead, e.g. `169.254.1.29:3000`.

With the `secure-node.nix` or `enable-tor.nix` preset, RTL also has an onion service.
Open `http://<onion address>` in Tor Browser, using the address from
`nodeinfo | jq -r .rtl.onion_address`.

The password is in `$secretsDir/rtl-password`.
See: [Secrets dir](./configuration.md#secrets-dir)

#### Backend maintenance

RTL is bound to the units of its backends. It stops when the lnd or clightning unit
stops, crashes or exits, and the backend's next start starts it again. With both
backends enabled, stopping one of them also stops RTL for the other one, and
starting RTL starts a stopped backend too. So during maintenance of one backend,
leave RTL stopped.

#### Backend certificates

A connection from RTL to a backend's address and port must present that backend's
pinned certificate: `services.lnd.certPath` for lnd, or `server.pem` in clnrest's cert
dir (clightning's network dir, or `clnrest-certs`). So a local process that takes a
backend's port gets neither the lnd macaroon nor the clightning rune. Every other HTTPS
connection gets the normal certificate and hostname checks against the system CAs.
RTL doesn't start when `LN_SERVER_URL` or `LND_SERVER_URL` is set in its environment.
To use another server with a self-signed certificate, for example a swap server set
through `extraConfig`, add its certificate to RTL's environment with
`systemd.services.rtl.environment.NODE_EXTRA_CA_CERTS`.

#### Reset two-factor authentication

Two-factor authentication that you set up in RTL stays on across restarts. If you
lose the authenticator, delete `RTL-Config.json` in RTL's data dir
(`/var/lib/rtl` by default) and restart RTL. bitcoinix then writes a new one
without the 2FA secret.

### Connect to BTCPay Server

BTCPay Server listens on localhost by default. Connect to it through an SSH tunnel, then
open `http://localhost:23000` in your browser:

```
ssh -L 23000:127.0.0.1:23000 operator@bitcoin-node
```

With `netns-isolation`, BTCPay Server listens in its own network namespace. Use the address
from `nodeinfo | jq -r .btcpayserver.local_address` instead, e.g. `169.254.1.24:23000`.

BTCPay Server makes the first account that registers the server admin, which can use the
internal Lightning node. So when BTCPay Server has no admin, the unit `btcpayserver-admin`
creates the admin account `admin@localhost` before BTCPay Server opens its port. BTCPay
Server then closes registration. Sign in with this account. The password is in
`$secretsDir/btcpayserver-admin-password`.
See: [Secrets dir](./configuration.md#secrets-dir)

An installation that already had an admin before bitcoinix 0.2.0 keeps it and gets no
`admin@localhost`. Sign in with your own account there.

You can change the account's email address and password in BTCPay Server. The secret file
keeps the first password.

#### Check the admin accounts

Before bitcoinix 0.2.0, any local user could register first and become the admin until
you registered yours. So on an installation from before 0.2.0, check that each admin is
yours. Sign in, open Server Settings > Users and look at the users with the admin role.

If one isn't yours, or if you found registration closed before you registered, someone
else had admin access. An admin can install plugins that run as the `btcpayserver` user
and can use your Lightning node. So treat the node as compromised:

1. Stop BTCPay Server with `systemctl stop btcpayserver`.
2. Move the funds of the Lightning node and of the wallets on this node to a new wallet
   that this node doesn't control.
3. Set up the node again.

### BTCPay Server

#### Lightning backend

`services.btcpayserver.lightningBackend` connects BTCPay Server to the node's lnd or
Core Lightning. The two backends give BTCPay Server different access.

With `lnd`, BTCPay Server gets its own macaroon, `services.lnd.macaroons.btcpayserver`
(see [Custom macaroons](#custom-macaroons)). It can read the node's state and create
invoices and addresses. It can't send funds or open or close channels, so BTCPay
Server can't make Lightning payouts.

With `clightning`, BTCPay Server has full control of the Lightning node, including its
funds. It joins the clightning group and uses lightningd's RPC socket `lightning-rpc`,
which allows every method. So BTCPay Server can pay invoices (`pay`, `xpay`), send
on-chain funds (`withdraw`), open and close channels (`fundchannel`, `close`) and start
plugins (`plugin`), which run as the clightning user. With clnrest enabled, the group
can also read clnrest's admin rune. A bug in BTCPay Server, a malicious BTCPay plugin or
a stolen admin session can drain the node. The pinned BTCPay Server 2.4.7 uses
BTCPayServer.Lightning 1.7.14, whose Core Lightning client connects only over this
socket or TCP and can't use runes. So bitcoinix can't give it restricted access yet.

The backend limits only what BTCPay Server can do with the Lightning node. A hot wallet
that you create in BTCPay Server keeps its keys on the node, so BTCPay Server can spend it
with either backend.

Use `lnd` when you want BTCPay Server limited, for example when its web interface is
reachable from the internet. bitcoinix turns on Core Lightning for BTCPay Server only
while it's the backend. So if your Core Lightning has channels, set
`services.clightning.enable = true` before you switch, or close the channels first.
Otherwise the switch stops Core Lightning, and nothing watches its channels. Both
daemons use port 9735 by default, so also give lnd another port, for example
`services.lnd.port = 9736;`.

### Connect to Unbeholden Wallet
[Unbeholden Wallet](https://github.com/unbeholdendev/unbeholden-wallet) is a watch-only
wallet that runs in the browser and hands transactions to an air-gapped signer over QR
codes. The service serves the wallet and passes its connection on to electrs, or to Fulcrum
with `services.unbeholden-wallet.electrumServer = "fulcrum"`.

```nix
services.unbeholden-wallet.enable = true;
```

It listens on localhost. Connect through an SSH tunnel, then open `http://localhost:60846`
and press Connect:

```
ssh -L 60846:127.0.0.1:60846 operator@bitcoin-node
```

With `netns-isolation`, use the address from `nodeinfo | jq -r '.["unbeholden-wallet"].local_address'`
instead.

#### Access from another device

Browsers only allow the camera, which scans the signed transaction, on `localhost` or
over https. To use the wallet from another device without a tunnel, put an https reverse
proxy in front of it that passes WebSocket upgrades and the `Host` header through, and add
its name to `services.unbeholden-wallet.allowedHosts`.

The service only accepts connections from localhost. For a proxy on another host, listen on
all addresses, allow the proxy's address and open the port:

```nix
services.unbeholden-wallet = {
  address = "0.0.0.0";
  allowedClients = [ "192.0.2.10" ];
  allowedHosts = [ "wallet.example.com" ];
};
networking.firewall.allowedTCPPorts = [ 60846 ];
```

The service has no authentication. Its `Host` and `Origin` checks stop websites, not other
clients, so anyone who can reach the proxy can use the Electrum connection and write to the
service's journal. Keep the proxy on a trusted network or give it its own authentication.

With `netns-isolation`, nginx and the wallet run in their own namespaces, which drop
connections from your LAN, so neither an nginx proxy nor `allowedClients` serves other
devices. Run the proxy in the host network namespace instead, and point it at the wallet's
`local_address`.

### Use ZEUS (mobile Lightning wallet) via Tor
1. Install [ZEUS](https://zeusln.app)

2. Edit your `configuration.nix`

   ##### For LND

   Add the following config:
   ```nix
   services.lnd.lndconnect = {
     enable = true;
     onion = true;
   };
   ```

   ##### For Core Lightning

   Add the following config:
   ```nix
   services.clightning.plugins.clnrest = {
     enable = true;
     lnconnect = {
       enable = true;
       onion = true;
     };
   };
   ```

3. Deploy your configuration

4. Run the following command on your node (as user `operator`) to create a QR code
   with address and authentication information:

   ##### For LND
   ```
   lndconnect
   ```

   ##### For Core Lightning
   ```
   lnconnect-clnrest
   ```
   `lnconnect-clnrest` reads the onion address from the operator user's directory.
   The operator user gets access to it when the operator role is enabled
   (`nix-bitcoin.operator.enable = true;`, which the secure-node preset sets).
   With the role disabled, grant the access explicitly:
   ```nix
   nix-bitcoin.onionAddresses.access.<operator name> = [ "clnrest" ];
   ```
   `lnconnect-clnrest` also reads the admin rune, which only the `clightning` group can
   read. The operator role adds the operator user to this group. With the role disabled,
   run `lnconnect-clnrest` as root, or add the user to the group:
   ```nix
   users.users.<operator account>.extraGroups = [ "clightning" ];
   ```
   `<operator account>` is the `users.users` attribute that defines the account. It's
   usually the operator name.
   Members of this group can read the admin rune and use the clightning RPC socket,
   so they have full control over the node.

5. In ZEUS, add a new node and scan the QR code.

#### Additional lndconnect features
To print the connection URL as text instead of a QR code, run `lndconnect --url` or
`lnconnect-clnrest --url`. The URL contains the credentials for your node, so keep it
secret.

#### Connecting without Tor or WireGuard
Enabling `lndconnect` or `lnconnect` does not change the address that the REST server
listens on. By default, the LND and clnrest REST servers only listen
on localhost.

The REST API grants full control over your Lightning node, so only expose it to networks
you trust. To reach it directly (e.g. via your local network or your own VPN), opt in
explicitly. In the examples below, `192.168.1.10` is the address of your node and `eth0`
is the interface of the trusted network. The snippets use `config`, so the module that
contains them must take it as an argument (`{ config, ... }: { ... }`).\
These examples don't apply when using `netns-isolation`.

`tor.enforce = false` lifts the Tor-only network restriction for the whole service, not
just the REST server. With `tor.proxy`, outgoing connections still use Tor.

With `tor.enforce`, a service reaches only localhost and, with
[network namespace isolation](./configuration.md#network-namespace-isolation), its
namespace subnet. It can't use the local name-resolution sockets (nscd,
systemd-resolved, D-Bus, Avahi), so glibc resolves names itself, from `/etc/hosts`.

The restriction covers IP connections and these sockets, not every local service:

- Without netns-isolation, a resolver that listens on `127.0.0.1` or `::1`, such as a
  local `dnsmasq` or `unbound`, or `networking.nameservers = [ "127.0.0.1" ]`, stays
  reachable, because localhost is allowed and the restriction can't tell ports apart.
  The service can still send it DNS queries, which it may forward over clearnet. With
  netns-isolation each service has its own loopback, so a host resolver there is out of
  reach, unless the host firewall opens the resolver's port on all interfaces: the
  service can reach the bridge address on any port the firewall allows. Bind the
  resolver to an address outside the allow list if you don't want these services to
  use it.
- Another daemon you run that the service can reach over a Unix socket, and that makes
  network requests for its clients, isn't covered. Keep such daemons off nodes that
  rely on `tor.enforce`, or restrict access to their sockets.

##### For LND
```nix
services.lnd = {
  restAddress = "0.0.0.0";
  # Add the node address to the TLS certificate
  certificate.extraIPs = [ "192.168.1.10" ];
  # Only needed when using `secure-node.nix` or `enable-tor.nix`
  tor.enforce = false;
};
networking.firewall.interfaces.eth0.allowedTCPPorts = [ config.services.lnd.restPort ];
```

##### For Core Lightning
```nix
services.clightning = {
  plugins.clnrest.address = "0.0.0.0";
  # Only needed when using `secure-node.nix` or `enable-tor.nix`
  tor.enforce = false;
};
networking.firewall.interfaces.eth0.allowedTCPPorts = [ config.services.clightning.plugins.clnrest.port ];
```

Then create the QR code with your node address as the host:
```bash
lndconnect --host 192.168.1.10
lnconnect-clnrest --host 192.168.1.10
```
Always pass `--host` here. Without it (and without `onion`), the commands detect your
external IP by querying public IP lookup services over clearnet.
`lnconnect-clnrest` puts clnrest's server certificate into this URL. It asks clightning
for clnrest's cert dir (`clnrest-certs`). When clightning doesn't answer, it prints a
warning and uses clightning's network dir. So with `clnrest-certs` set, run it while
clightning runs, or pass `--tlscertpath`.

### Use ZEUS (mobile Lightning wallet) via WireGuard

Connecting ZEUS through a WireGuard tunnel is much faster than using Tor. The
`wireguard.nix` preset sets up a WireGuard server on your node with a single peer, your
mobile device. To use your own VPN instead, see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard).

#### WireGuard requirements

The preset requires:
- the NixOS firewall (`networking.firewall.enable`, set by the `secure-node.nix` preset)
  with the iptables backend. `networking.nftables` and `services.firewalld` must be
  disabled, because the preset protects the REST servers with iptables rules.
- no `netns-isolation`.

The preset binds the LND and clnrest REST servers to `0.0.0.0` and only allows REST
connections from the WireGuard peer through the firewall. It also sets `tor.enforce = false`
for the service whose connection helper you enable (see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard)).

#### Set up WireGuard and ZEUS

1. Install [ZEUS](https://zeusln.app) and
   [WireGuard](https://www.wireguard.com/install/) on your mobile device.

2. Import the preset. With the `flake.nix` example, add it to the `modules` list in
   `flake.nix`, next to `bitcoinix.nixosModules.default`:
   ```nix
   (bitcoinix + "/modules/presets/wireguard.nix")
   ```
   With Colmena, add `(inputs.bitcoinix + "/modules/presets/wireguard.nix")` to the
   `imports` of your node. With krops, add it to `configuration.nix`:
   ```nix
   imports = [ <nix-bitcoin/modules/presets/wireguard.nix> ];
   ```

   Then enable the connection helper:
   ```nix
   # For LND
   services.lnd.lndconnect.enable = true;

   # For Core Lightning
   services.clightning = {
     plugins.clnrest = {
       enable = true;
       lnconnect.enable = true;
     };
   };
   ```
   For custom firewall configurations, review
   [WireGuard firewall compatibility](#wireguard-firewall-compatibility) before deploying.

3. Deploy your configuration.

4. If your node is behind an external firewall or NAT (e.g. a router), add the following port forwarding
   rule to the external device:
   - Port: 51820 (the default value of option `networking.wireguard.interfaces.wg-nb.listenPort`)
   - Protocol: UDP
   - Destination: IP of your node

5. Set up WireGuard on your mobile device.

   Run the following command on your node (as user `operator`) to create a QR code
   for WireGuard, with the public IP or hostname of your node:
   ```bash
   nix-bitcoin-wg-connect 93.184.216.34
   nix-bitcoin-wg-connect mynode.example.com

   # For debugging: Show the WireGuard config as text
   nix-bitcoin-wg-connect --text mynode.example.com
   ```
   The address is required. `nix-bitcoin-wg-connect` doesn't look up your node's public
   IP, since that would reveal it to public IP lookup services over clearnet. Behind NAT,
   your router shows the public IP. For a device that connects only from your local
   network, you can pass the node's LAN IP instead.

   In the WireGuard app, add a tunnel by scanning the QR code.

6. Set up ZEUS

   Run the following command on your node (as user `operator`) to create a QR code for ZEUS:

   ##### For LND
   ```
   lndconnect-wg
   ```

   ##### For Core Lightning
   ```
   lnconnect-clnrest-wg
   ```

   In ZEUS, add a new node and scan the QR code. The QR code contains no TLS certificate,
   so ZEUS may warn about it; the WireGuard tunnel encrypts the connection.

To print the connection URL as text instead, run `lndconnect-wg --url` or
`lnconnect-clnrest-wg --url`.

#### WireGuard firewall compatibility

The preset guards the REST API with `networking.firewall.extraCommands` rules. They need
the iptables firewall backend and `iptables` on the firewall service's PATH, and firewalld
isn't supported. `networking.nftables` can stay enabled if you set
`networking.firewall.backend = "iptables"` and `networking.firewall.package = pkgs.iptables`
(or add `pkgs.iptables` to `networking.firewall.extraPackages`). Then put your own nftables
rules in `networking.nftables.tables` and keep `networking.nftables.flushRuleset = false`.
Flushing the ruleset deletes the preset's rules. It's on by default when
`networking.nftables.ruleset` or `rulesetFile` is set or `system.stateVersion` is older than 23.11.
Don't name a table `filter` in the `ip` or `ip6` family, since iptables keeps its rules there.

Neither applies when the firewall runs `pkgs.iptables-legacy`, whose rules live outside the
nftables ruleset: set it as `networking.firewall.package`, or keep the default nftables
package and put it first in `networking.firewall.extraPackages`.
iptables-legacy needs a kernel with legacy xtables (`CONFIG_NETFILTER_XTABLES_LEGACY`,
or `CONFIG_IP_NF_IPTABLES_LEGACY` on older kernels).
The default kernel doesn't enable them, and `firewall.service` then fails to start.
`pkgs.linuxPackages_6_12` has them, so set `boot.kernelPackages` to it and reboot.

If you fix either of these on a running node, run `systemctl restart firewall` once after
deploying, since the first reload still runs the old deletions.

<a id="initialize-a-trezor-for-bitcoin-cores-hardware-wallet-interface"></a>

### Initialize a Trezor for the Bitcoin Hardware Wallet Interface (HWI)

1. Enable Trezor support in your configuration:
    ```nix
    services.hardware-wallets.trezor = true;
    ```
    This installs `hwi`, `trezorctl` and `lsusb`, and adds udev rules that give group
    `hardware-wallets` access to the device. Only members of that group can use it,
    unless you run the Trezor Bridge (see below). The `operator` user is in that group.
    Hardware wallets require the bitcoind wallet, so `services.bitcoind.disablewallet`
    must stay unset or `false`.

2. Deploy your configuration.

3. Plug in your Trezor and check that your node recognizes it:

    ```
    ssh operator@bitcoin-node
    lsusb
    ```

4. If your Trezor's firmware is outdated, update it:

    ```
    trezorctl firmware update
    ```
    Keep your recovery seed at hand: a firmware update can wipe the device. See
    [Trezor's firmware guide](https://trezor.io/learn/a/update-trezor-device-firmware)
    for the bootloader mode of your model.

5. If your Trezor is not yet initialized, set it up with a PIN:

    ```
    trezorctl device setup -p
    ```

6. Find your Trezor:

    ```
    hwi enumerate
    ```
    A Trezor One asks for its PIN through HWI:
    ```
    hwi -t trezor -d <path from previous command> promptpin
    hwi -t trezor -d <path> sendpin <number positions for the PIN as displayed on your device's screen>
    hwi enumerate
    ```

7. Follow HWI's guide on [using Bitcoin Core with hardware wallets](https://hwi.readthedocs.io/en/latest/examples/bitcoin-core-usage.html) to use your Trezor with `bitcoin-cli` on your node.

The Trezor Bridge (`trezord`) doesn't run by default, since HWI and `trezorctl` don't
need it. To run it for apps that use it, set `services.hardware-wallets.trezorBridge = true;`.
The bridge serves an HTTP API without authentication on `127.0.0.1:21325`, so every
local user and service can then use the Trezor through it.

## LND

### Custom macaroons

`services.lnd.macaroons.<name>` gives a service its own macaroon with only the
permissions it needs. Each time lnd starts, bitcoinix creates the macaroon at
`/run/lnd/<name>.macaroon`, readable only by `user`. BTCPay Server and charge-lnd get
their macaroons this way.

```nix
services.lnd.macaroons.myapp = {
  user = "myapp";
  permissions = ''{"entity":"info","action":"read"},{"entity":"invoices","action":"write"}'';
};
```

#### Root keys and configuration changes

Each custom macaroon has its own lnd root key. Its ID,
`services.lnd.macaroons.<name>.rootKeyId`, is derived from the name, user and
permissions, so copies of the macaroon stay valid when lnd restarts. A change of
the name, user or permissions gives the macaroon a new ID. Each time lnd starts,
bitcoinix deletes the root key of every ID from 7953919891889717248 to
7954201366866427903 (`0x6e62000000000000` to `0x6e62ffffffffffff`) that no
configured macaroon uses. If it deleted a root key, it restarts lnd once more,
which closes the connections that use these macaroons. If this restart fails
while the old lnd process still runs, it stops lnd. So when you change or
remove a macaroon, its copies stop working when lnd restarts during the
deployment. Until then, a leaked copy keeps working. Copies created before
bitcoinix 0.1.6 are an exception: they use root key 0 and stay valid until you
[revoke all macaroons](#revoke-all-macaroons). Don't use IDs in this range for
macaroons that you bake yourself.

bitcoinix creates the macaroons and deletes the stale root keys with `lncli`,
lnd's admin macaroon and gRPC. It does this each time lnd starts, also without
custom macaroons, so lnd must keep its macaroons enabled: the `no-macaroons`
option isn't supported.

#### Restart services after macaroon changes

A service that reads its macaroon only at startup must restart to read the new
macaroon. Restart it on deployments that change the macaroon:

```nix
systemd.services.myapp.restartTriggers = [ config.services.lnd.macaroons.myapp.rootKeyId ];
```

BTCPay Server reads its macaroon for each request to lnd, and charge-lnd for each
run.

#### Revoke a macaroon

To revoke all copies of a macaroon without changing its configuration:

1. Find the root key ID of the macaroon in lnd's log:
   ```
   journalctl -b -u lnd --grep 'Create custom macaroon myapp'
   ```
   `lncli listmacaroonids` lists all root key IDs.
2. Delete the root key: `lncli deletemacaroonid <ID>`
3. Restart lnd: `systemctl restart lnd`. This closes the connections that use the
   macaroon. lnd creates a new root key with the same ID, and bitcoinix creates a new
   `/run/lnd/myapp.macaroon`.
4. Restart the service that uses the macaroon.

#### Revoke all macaroons

lnd's default macaroons, like `admin.macaroon`, share root key 0, and so do
custom macaroons created before bitcoinix 0.1.6. lnd can't delete root key 0. To revoke
these macaroons, replace all root keys. `lncli changepassword --new_mac_root_key`
doesn't work on bitcoinix, because lnd unlocks the wallet when it starts. Instead,
delete the macaroon database and the macaroon files in the lnd network dir
(`services.lnd.networkDir`) while lnd is stopped. This works with lnd's default
database backend (bbolt). With another `db.backend` in `services.lnd.extraConfig`,
the root keys are in that database instead. Run as root:

1. Keep a copy of the current admin macaroon, to check at the end that old
   macaroons stop working:
   ```
   runuser -u lnd -- cp /var/lib/lnd/chain/bitcoin/mainnet/admin.macaroon /var/lib/lnd/old-admin.macaroon
   ```
   Then stop lnd and the units that can start it, so that none starts lnd during the
   next step: `charge-lnd.timer` and the services that require or want lnd.
   `systemctl list-dependencies --reverse lnd.service` lists them. For example,
   with charge-lnd, BTCPay Server and RTL (leave out the ones your node doesn't have):
   ```
   systemctl stop charge-lnd.timer charge-lnd btcpayserver rtl lnd
   ```
2. Delete the files as the lnd user, here for the default mainnet dir:
   ```
   runuser -u lnd -- sh -c 'cd /var/lib/lnd/chain/bitcoin/mainnet && rm -f macaroons.db *.macaroon'
   ```
3. Restart lnd, so that a fresh process opens the new database. Check that the new
   admin macaroon works and the old copy doesn't:
   ```
   systemctl restart lnd
   lncli --profile= getinfo
   lncli --profile= --macaroonpath /var/lib/lnd/old-admin.macaroon getinfo
   ```
   `--profile=` makes lncli ignore a saved default profile. The first `getinfo` must
   work and the second must fail with an authentication error. If not, a unit
   (bitcoind too) started lnd during step 2. Run the `stop` command from step 1
   again, then steps 2 and 3, and keep the old copy.
   Then delete the copy: `runuser -u lnd -- rm /var/lib/lnd/old-admin.macaroon`.
4. Start the units that you stopped, for example
   `systemctl start charge-lnd.timer btcpayserver rtl`. RTL copies the admin
   macaroon when it starts.

lnd creates new root keys and new default macaroons, and bitcoinix creates new
custom macaroons. All earlier macaroons stop working. Then:

- Create new connection URLs with `lndconnect` or `lndconnect-wg` and connect your
  wallets again.
- Bake new macaroons for the macaroons that you baked yourself.

<a id="clightning"></a>

## Core Lightning

Core Lightning (CLN), formerly c-lightning, uses the `services.clightning`
options, `clightning` systemd service, and `lightning-cli` command in bitcoinix.

### Plugins
There are a number of [plugins](https://github.com/lightningd/plugins) available for Core Lightning.
See [`README: Features → Core Lightning`](https://github.com/bitcoinix/bitcoinix/blob/master/README.md) or [search.nixos.org][1] for a complete list.

[1]: https://search.nixos.org/flakes?channel=unstable&from=0&size=30&sort=relevance&type=options&query=services.clightning.plugins

You can activate and configure these plugins like so:

```nix
services.clightning = {
  enable = true;
  plugins = {
    clboss.enable = true;
    clboss.min-onchain = 40000;
  };
};
```

Please have a look at the module for a plugin (e.g. [clboss.nix](https://github.com/bitcoinix/bitcoinix/blob/master/modules/clightning-plugins/clboss.nix)) to learn its configuration options.

#### Currency rates

Enable the Rust [cln-currencyrate plugin](https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin):

```nix
services.clightning.plugins.currencyrate.enable = true;
```

Use `lightning-cli currencyconvert 100 USD` to convert a fiat amount into
millisatoshis, `lightning-cli listcurrencyrates USD` to list source prices in
USD per BTC, or `lightning-cli currencyrate USD` to get the median rate.

For custom price sources, set `currencyrate-add-source` and
`currencyrate-disable-source` in `services.clightning.extraConfig`; see the
[upstream plugin documentation](https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin).
The plugin follows CLN's configured proxy and shares its service sandbox and
network namespace.

If you used the former Python plugin, follow the
[currencyrate migration instructions](./upgrading/0.1.5.md).

#### Trustedcoin
When `services.clightning.tor.proxy` is enabled, [trustedcoin](https://github.com/nbd-wtf/trustedcoin)
also uses Tor for all external connections by default.
In this case, connections to block explorers can sometimes get blocked.

An example of Core Lightning log error output when connections are getting blocked:
```
lightningd[5138]: plugin-trustedcoin estimatefees error: https://blockstream.info/api error: 403 Forbidden
lightningd[4933]: plugin-trustedcoin getblock error: got something that isn't a block hash: <html><head>...
```

To work around this and connect via clearnet instead, set this option:
```nix
services.clightning.plugins.trustedcoin.tor.proxy = false;
```
This also disables `services.clightning.tor.enforce`, so the whole `clightning` service
is no longer restricted to Tor.

<a id="clightning-database-replication"></a>

### Core Lightning database replication

Core Lightning can write a live copy of its database to a local path
or to a remote SSH target (mounted via SSHFS).
Optionally, the copy can be encrypted with `gocryptfs`.
See the [module](https://github.com/bitcoinix/bitcoinix/blob/master/modules/clightning-replication.nix)
for all options.

`clightning` requires the replication target: it doesn't start while the target is
unavailable, e.g. when the SSHFS mount fails. For a local directory, this works only
when systemd knows the mount that holds the directory. See
[Local directory target](#local-directory-target).

Also back up:
- the static file `hsm_secret` (`/var/lib/clightning/bitcoin/hsm_secret` by default).
  The `services.backups` module includes it.
- with `encrypt`, the password `$secretsDir/clightning-replication-password`. Without it,
  the copy can't be decrypted. `services.backups` includes the secrets dir only
  with `nix-bitcoin.generateSecrets`.

#### Remote target via SSHFS

1. Add this to your configuration:
   ```nix
   services.clightning.replication = {
     enable = true;
     sshfs.destination = "user@hostname:directory";
     # This is optional
     encrypt = true;
   };
   programs.ssh.knownHosts."hostname".publicKey = "<contents of /etc/ssh/ssh_host_ed25519_key.pub on the target>";
   ```

   Leave out the `encrypt` line if you want to store data on your destination
   in plaintext.\
   Adjust `user`, `hostname` and `directory` as necessary. `directory` is relative to
   the home of `user`. If the target's SSH server doesn't listen on port 22, set
   `sshfs.port` and use `"[hostname]:<port>"` as the `knownHosts` name.

   The `knownHosts` entry is required: the mount runs without a terminal, so SSH
   can't ask you to accept an unknown host key and the mount fails.
   Read the host key on the target itself, not with `ssh-keyscan` from the node,
   which trusts whatever host answers.
   Don't add `StrictHostKeyChecking=no` to `sshfs.sshOptions`. It allows any host
   on the network path to impersonate the target and receive the database,
   in plaintext without `encrypt`.

2. Deploy. With `nix-bitcoin.generateSecrets`, this creates the SSH key
   `$secretsDir/clightning-replication-ssh-key`.
   `clightning` starts only once the target accepts this key (step 3).

3. To allow SSH access from the bitcoinix node to the target node, either
   use the remote node config below, or copy the contents of `$secretsDir/clightning-replication-ssh-key.pub`
   to the `authorized_keys` file of `user` (or use `ssh-copy-id`).
   Then run `systemctl restart clightning` as root.

4. You can restrict the bitcoinix node's capabilities on the SSHFS target
   to SFTP access in a chroot.
   To implement this on NixOS, add the following to the NixOS configuration of
   the SSHFS target node:
   ```nix
   systemd.tmpfiles.rules = [
     # Because this directory is chrooted by sshd, it must only be writable by user/group root
     "d /var/backup/nb-replication 0755 root root - -"
     "d /var/backup/nb-replication/writable 0700 nb-replication - - -"
   ];

   services.openssh = {
     extraConfig = ''
       Match user nb-replication
         ChrootDirectory /var/backup/nb-replication
         AllowTcpForwarding no
         AllowAgentForwarding no
         ForceCommand internal-sftp
         PasswordAuthentication no
         X11Forwarding no
     '';
   };

   users.users.nb-replication = {
     isSystemUser = true;
     group = "nb-replication";
     shell = "${pkgs.coreutils}/bin/false";
     openssh.authorizedKeys.keys = [ "<contents of $secretsDir/clightning-replication-ssh-key.pub>" ];
   };
   users.groups.nb-replication = {};
   ```

   With this setup, the corresponding `sshfs.destination` on the bitcoinix
   node is `"nb-replication@hostname:writable"`.

#### Local directory target

1. Add this to your configuration:
   ```nix
   services.clightning.replication = {
     enable = true;
     local.directory = "/var/backup/clightning";
     encrypt = true;
   };
   ```

   Leave out the `encrypt` line if you want to store data in
   `local.directory` in plaintext.

2. Deploy

Core Lightning will now replicate database files to `local.directory`. This
can be used to replicate to an external HDD by mounting it at path
`local.directory`.

`clightning` requires the mounts for `local.directory`. With `encrypt`,
`clightning-replication-mounts` requires them too. While the disk isn't mounted,
`clightning` doesn't start, so the replica can't land on the primary disk.
systemd can only wait for the mounts it knows, so declare the disk in `fileSystems`:
```nix
fileSystems."/var/backup/clightning" = {
  device = "/dev/disk/by-uuid/<uuid of the disk's filesystem>";
  fsType = "ext4";
  # Boot without the disk. clightning stays stopped then.
  options = [ "nofail" ];
};
```
systemd finds the mounts from the path as written and doesn't follow symlinks.
So set `local.directory` to the mount point or a directory below it, not to a
symlink. A directory on the root filesystem has no mount to wait for.

#### Custom remote destination

Follow the steps in section "Local directory target" above and mount a custom remote
destination (e.g., an NFS or SMB share) to `local.directory`. Declare the share in
`fileSystems`, so that `clightning` doesn't start without it.\
You might want to disable `local.setupDirectory` in order to create the mount directory
yourself with custom permissions.

## rbitcoin

[rbitcoin](https://github.com/rbitcoin-org/rbitcoin) is an **experimental**
Bitcoin full node written in Rust, with built-in Electrum and Esplora servers.
It is a separate implementation of the consensus rules, not a build of Bitcoin
Core. Run it as an extra node, or as mempool's node in place of bitcoind:

```nix
services.mempool.enable = true;
services.mempool.electrumServer = "rbitcoin";
```

Things to know before enabling it:

- **Ports.** rbitcoin's defaults are Bitcoin Core's (P2P 8333, RPC 8332,
  Electrum 50001). If bitcoind, electrs or fulcrum also run on the host
  without netns isolation (e.g. with `secure-node.nix`, which enables
  bitcoind), set `services.rbitcoin.port`, `rpc.port` and `electrum.port`
  to free ports; evaluation fails on a collision.
- **The RPC cookie is an admin credential.** rbitcoin has no restricted or
  read-only credential: anyone who can read the cookie (group `rbitcoinrpc`,
  which includes the mempool user) can call every method, including `stop`
  and `invalidateblock`. With bitcoind, mempool only holds a whitelisted
  `public` user, so a compromised mempool backend is a bigger risk here.
- **Own data directory.** rbitcoin keeps its own archive format
  (`services.rbitcoin.dataDir`, default `/var/lib/rbitcoin`) and cannot reuse
  bitcoind's blocks. A mainnet sync downloads and stores the whole chain again.
- **Upgrades can be one-way.** A new rbitcoin version may rewrite the data
  directory to a newer schema on its first start, and the older version then
  refuses to open it. Read the upstream release notes before an upgrade.
  0.9.2 (schema 27) also asks for a re-sync of a store that connected an
  invalid re-spend during IBD under an earlier version.
- **Address index.** `services.rbitcoin.electrum.enable` turns on the
  scripthash index. It is built after the node reaches the tip, which takes
  several hours on mainnet, and the Electrum port only opens once it is ready.
- **RPC.** With `services.rbitcoin.rpc.enable`, rbitcoin serves a Bitcoin Core
  compatible JSON-RPC subset over TCP. Clients authenticate with the cookie at
  `/run/rbitcoin/rpc.cookie`, readable by group `rbitcoinrpc`. The cookie
  changes on every start, so clients should read it from that path (mempool
  does). The operator's `rbitcoin-cli` uses the unix socket in `dataDir`.
  The cookie is mode 0640 so that group `rbitcoinrpc` can read it. rbitcoin
  refuses a cookie with group bits unless started with
  `--rpc-cookie-perms group`, which the module passes. (Earlier rbitcoin
  versions only logged a warning.)
- **Tor.** With `services.rbitcoin.tor.proxy` (enabled by `secure-node.nix`),
  all P2P connections, including DNS seed lookups, go through Tor.
- **Large addresses.** `services.rbitcoin.maxShCreates` (default 10000)
  refuses unpaged history and balance queries for scripts with more outputs,
  so mempool cannot show such addresses. Each of these queries loads every
  output: on a mainnet node with 4 GiB RAM, scripts with 100k outputs took up
  to about a minute and 2 GiB, and some scripts have millions. Raise the cap
  only with RAM to spare.
- **Network isolation.** With `nix-bitcoin.netns-isolation.enable`, rbitcoin
  runs in its own network namespace. Services that should reach it list
  `rbitcoin` in their `connections` (mempool does this automatically). If
  `services.rbitcoin.connect` points at a local bitcoind, also set
  `nix-bitcoin.netns-isolation.services.rbitcoin.connections = [ "bitcoind" ];`.
