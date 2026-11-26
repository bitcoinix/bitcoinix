# ZEUS

Connect ZEUS to your LND or Core Lightning node over Tor or WireGuard.

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

## Connect via Tor
1. Install [ZEUS](https://zeusln.app)

2. Edit your `configuration.nix`

   #### For LND

   Add the following config:
   ```nix
   services.lnd.lndconnect = {
     enable = true;
     onion = true;
   };
   ```

   #### For Core Lightning

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

   #### For LND
   ```
   lndconnect
   ```

   #### For Core Lightning
   ```
   lnconnect-clnrest
   ```
   `lnconnect-clnrest` reads the onion address from the directory of the user that runs
   it. Root can always run it, because then it runs as the `clightning` user, which has
   its own copy. The operator user needs access to the onion address only to run
   `lnconnect-clnrest` as itself. It gets this access when the operator role is enabled
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

### Additional lndconnect features
To print the connection URL as text instead of a QR code, run `lndconnect --url` or
`lnconnect-clnrest --url`. The URL contains the credentials for your node, so keep it
secret.

With `onion`, the commands fail when they can't read the onion address, for example
while Tor still starts. They never look up your public IP then. `--host` replaces the
onion address.

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

With `tor.enforce`, a service reaches only localhost and, with
[network namespace isolation](../configuration.md#network-namespace-isolation), its
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

#### For LND
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

#### For Core Lightning
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

## Connect via WireGuard

Connecting ZEUS through a WireGuard tunnel is much faster than using Tor. The
`wireguard.nix` preset sets up a WireGuard server on your node with a single peer, your
mobile device. To use your own VPN instead, see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard).

### WireGuard requirements

The preset requires:
- the NixOS firewall (`networking.firewall.enable`, set by the `secure-node.nix` preset)
  with the iptables backend. `networking.nftables` and `services.firewalld` must be
  disabled, because the preset protects the REST servers with iptables rules.
- no `netns-isolation`.

The preset binds the LND and clnrest REST servers to `0.0.0.0` and only allows REST
connections from the WireGuard peer through the firewall. It also sets `tor.enforce = false`
for the service whose connection helper you enable (see
[Connecting without Tor or WireGuard](#connecting-without-tor-or-wireguard)).

### Set up WireGuard and ZEUS

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

   #### For LND
   ```
   lndconnect-wg
   ```

   #### For Core Lightning
   ```
   lnconnect-clnrest-wg
   ```

   In ZEUS, add a new node and scan the QR code. The QR code contains no TLS certificate,
   so ZEUS may warn about it; the WireGuard tunnel encrypts the connection.

To print the connection URL as text instead, run `lndconnect-wg --url` or
`lnconnect-clnrest-wg --url`.

### WireGuard firewall compatibility

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
