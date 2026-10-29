> [!NOTE]
> This document is inherited from nix-bitcoin, the predecessor project. It is a work in progress and may be outdated.

# Nodeinfo
Run `nodeinfo` as user `operator` (or root) to see onion addresses and local addresses
for enabled services, and the node IDs of LND and Core Lightning. It prints JSON:
```shell
nodeinfo
nodeinfo | jq -r .bitcoind.onion_address
```
`nodeinfo` and `jq` are included in the `secure-node.nix` preset. Without the preset,
set `nix-bitcoin.nodeinfo.enable = true` and install `jq` for the example above.

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

# Managing services

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

<a id="clightning-database-replication"></a>

# Core Lightning database replication

The Core Lightning database can be replicated to a local path
or to a remote SSH target.\
When remote replication is enabled, bitcoinix mounts an SSHFS to a local path.\
Optionally, backups can be encrypted via `gocryptfs`.

Note: You should also back up the static file `hsm_secret` (located at
`/var/lib/clightning/bitcoin/hsm_secret` by default), either manually
or via the `services.backups` module.

## Remote target via SSHFS

1. Add this to your `configuration.nix`:
   ```nix
   services.clightning.replication = {
     enable = true;
     sshfs.destination = "user@hostname:directory";
     # This is optional
     encrypt = true;
   };
   programs.ssh.knownHosts."hostname".publicKey = "<ssh public key from running `ssh-keyscan` on the host>";
   ```

   Leave out the `encrypt` line if you want to store data on your destination
   in plaintext.\
   Adjust `user`, `hostname` and `directory` as necessary.

2. Deploy

3. To allow SSH access from the bitcoinix node to the target node, either
   use the remote node config below, or copy the contents of `$secretsDir/clightning-replication-ssh-key.pub`
   to the `authorized_keys` file of `user` (or use `ssh-copy-id`).

4. You can restrict the bitcoinix node's capabilities on the SSHFS target
   using OpenSSH's built-in features, as detailed
   [here](https://serverfault.com/questions/354615/allow-sftp-but-disallow-ssh).

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

## Local directory target

1. Add this to your `configuration.nix`
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

## Custom remote destination

Follow the steps in section "Local directory target" above and mount a custom remote
destination (e.g., an NFS or SMB share) to `local.directory`.\
You might want to disable `local.setupDirectory` in order to create the mount directory
yourself with custom permissions.

# Connect to RTL
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

# Use ZEUS (mobile Lightning wallet) via Tor
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

5. In ZEUS, add a new node and scan the QR code.

### Additional lndconnect features
To print the connection URL as text instead of a QR code, run `lndconnect --url` or
`lnconnect-clnrest --url`. The URL contains the credentials for your node, so keep it
secret.

### Connecting without Tor or WireGuard
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

# Use ZEUS (mobile Lightning wallet) via WireGuard

Connecting ZEUS through a WireGuard tunnel is much faster than using Tor. The
`wireguard.nix` preset sets up a WireGuard server on your node with a single peer, your
mobile device. To use your own VPN instead, see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard).

The preset requires:
- the NixOS firewall (`networking.firewall.enable`, set by the `secure-node.nix` preset)
  with the iptables backend. `networking.nftables` and `services.firewalld` must be
  disabled, because the preset protects the REST servers with iptables rules.
- no `netns-isolation`.

The preset binds the LND and clnrest REST servers to `0.0.0.0` and only allows REST
connections from the WireGuard peer through the firewall. It also sets `tor.enforce = false`
for the service whose connection helper you enable (see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard)).

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
   Without an argument, `nix-bitcoin-wg-connect` detects your node's external IP by
   querying public IP lookup services over clearnet.

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

# Connect to electrs
Electrum wallets can connect to your electrs (or Fulcrum) server through its onion
service, which the `secure-node.nix` and `enable-tor.nix` presets create.

<a id="requirements-android"></a>

### Android requirements
* [Orbot](https://guardianproject.info/apps/org.torproject.android/) from F-Droid or [Google Play](https://play.google.com/store/apps/details?id=org.torproject.android)
* [Electrum](https://electrum.org/#download) from the direct download or [Google Play](https://play.google.com/store/apps/details?id=org.electrum.electrum)

<a id="requirements-desktop"></a>

### Desktop requirements
* [Tor](https://support.torproject.org/little-t-tor/), listening on its default SOCKS port 9050
* [Electrum](https://electrum.org/#download)

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

# Connect to bitcoinix node through the SSH onion service
1. Get the SSH onion address (excluding the port suffix)

    ```
    ssh operator@bitcoin-node
    nodeinfo | jq -r .sshd.onion_address | sed 's/:.*//'
    ```

2. Create an SSH key

    ```
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
    ```

3. Place the Ed25519 public key in the `configuration.nix` `openssh.authorizedKeys.keys` field like so

    ```
    # FIXME: Add your SSH pubkey
    services.openssh.enable = true;
    users.users.root = {
      openssh.authorizedKeys.keys = [ "<contents of ~/.ssh/id_ed25519.pub>" ];
    };
    ```

4. Connect to your bitcoinix node's SSH onion service, forwarding a local port to the bitcoinix node's SSH server

    ```
    ssh -i ~/.ssh/id_ed25519 -L <random port of your choosing>:127.0.0.1:22 root@<SSH onion address>
    ```

5. Edit your deployment tool's configuration and change the node's address to `127.0.0.1` and the SSH port to `<random port of your choosing>`.
   If you use krops as described in the [installation tutorial](./install.md), set `target = "127.0.0.1:<random port of your choosing>";` in `krops/deploy.nix`.

6. After deploying the new configuration, it will connect through the SSH tunnel you established in step 4. This also allows you to do more complex SSH setups that some deployment tools don't support. An example would be authenticating with [Trezor's SSH agent](https://github.com/romanz/trezor-agent), which provides extra security.

<a id="initialize-a-trezor-for-bitcoin-cores-hardware-wallet-interface"></a>

# Initialize a Trezor for the Bitcoin Hardware Wallet Interface (HWI)

1. Enable Trezor in `configuration.nix`

    Change
    ```
    # services.hardware-wallets.trezor = true;
    ```
    to
    ```
    services.hardware-wallets.trezor = true;
    ```

2. Deploy new `configuration.nix`

3. Check that your bitcoinix node recognizes your Trezor

    ```
    ssh operator@bitcoin-node
    lsusb
    ```
    Should show something relating to your Trezor

4. If your Trezor has outdated firmware or is not yet initialized: Start your Trezor in bootloader mode

    Trezor v1
    ```
    Plug in your Trezor with both buttons depressed
    ```

    Trezor v2
    ```
    Start swiping your finger across your Trezor's touchscreen and plug in the USB cable when your finger is halfway through
    ```

5. If your Trezor's firmware is outdated: Update your Trezor's firmware

    ```
    trezorctl firmware-update
    ```
    Follow the on-screen instructions

    **Caution: This command _will_ wipe your Trezor. If you already store Bitcoin on it, only do this with the recovery seed nearby.**

6. If your Trezor is not yet initialized: Set up your Trezor

    ```
    trezorctl reset-device -p
    ```
    Follow the on-screen instructions

7. Find your Trezor

    ```
    hwi enumerate
    hwi -t trezor -d <path from previous command> promptpin
    hwi -t trezor -d <path> sendpin <number positions for the PIN as displayed on your device's screen>
    hwi enumerate
    ```

8. Follow Bitcoin Core's instructions on [Using Bitcoin Core with Hardware Wallets](https://github.com/bitcoin-core/HWI/blob/master/docs/bitcoin-core-usage.md) to use your Trezor with `bitcoin-cli` on your bitcoinix node

<a id="clightning"></a>

# Core Lightning

Core Lightning (CLN), formerly c-lightning, uses the `services.clightning`
options, `clightning` systemd service, and `lightning-cli` command in bitcoinix.

## Plugins
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

### Trustedcoin
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
