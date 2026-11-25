#### lndconnect and lnconnect-clnrest need the onion address

With `services.lnd.lndconnect.onion` or
`services.clightning.plugins.clnrest.lnconnect.onion`, `lndconnect` and
`lnconnect-clnrest` now fail when they can't read the onion address, for example while
Tor still starts or when the user has no access to it
(`nix-bitcoin.onionAddresses.access`). Before, they asked public services for the node's
IP over clearnet and printed a URL with that IP and the admin macaroon or rune. A
`--host` argument still replaces the onion address, and an empty `--host` is now an
error. With `onion`, `--localhost` and `--localip` only worked together with an empty
`--host` or while the onion address was missing. For a local URL, pass
`--host 127.0.0.1` or `--host` with the node's LAN IP.
