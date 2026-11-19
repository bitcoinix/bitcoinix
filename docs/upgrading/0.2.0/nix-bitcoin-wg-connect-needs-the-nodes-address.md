#### `nix-bitcoin-wg-connect` needs the node's address

`nix-bitcoin-wg-connect`, from the WireGuard preset, now needs the address where your
WireGuard client reaches the node. Before, it looked up the node's public IP when you
didn't pass an address. The lookup queried public IP lookup services over clearnet,
which revealed the IP to them, also on a node that otherwise uses only Tor. Without an
address, the command now prints a usage message and fails. Pass your node's public IP
or hostname, as described in [Set up WireGuard and ZEUS](../../services.md#set-up-wireguard-and-zeus):
```bash
nix-bitcoin-wg-connect 93.184.216.34
```
Scripts that call it without an address need the same change. Existing WireGuard
clients keep working.
