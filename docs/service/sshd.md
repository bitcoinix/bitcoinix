# SSH

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

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

## Keep the node's IP address private

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
