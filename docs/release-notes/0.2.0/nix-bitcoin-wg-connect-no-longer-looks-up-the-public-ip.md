#### `nix-bitcoin-wg-connect` no longer looks up the public IP

`nix-bitcoin-wg-connect` from the WireGuard preset now needs your node's address as an
argument. Before, it looked up the public IP through public IP lookup services over
clearnet when you passed no address. See
[Upgrading to config version 0.2.0](../../upgrading/0.2.0/nix-bitcoin-wg-connect-needs-the-nodes-address.md).
