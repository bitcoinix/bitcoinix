# Unbeholden Wallet

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

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

## Access from another device

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
