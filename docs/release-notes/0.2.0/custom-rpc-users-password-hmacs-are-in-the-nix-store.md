#### Custom RPC users' password HMACs are in the Nix store

The `passwordHMAC` of each custom RPC user in `services.bitcoind.rpc.users` is
written to the world-readable Nix store. Any local user can read it and test password
guesses offline. This isn't new, but it wasn't documented. If a custom RPC user has a
weak password, replace it with a long random one. See
[Allow bitcoind RPC connections from LAN](../../configuration.md#allow-bitcoind-rpc-connections-from-lan).
