#### Root runs CLI commands as the service user

`bitcoin-cli` now reads the config that bitcoinix generates from the Nix store, and
not the copy in the data dir. When root runs `bitcoin-cli`, it runs as the `bitcoin`
user. With the `bitcoind-remote.nix` preset, the credentials for the remote node are
now in `/run/bitcoind/.cookie` and not in `bitcoin.conf`.

When root runs `lightning-cli` or `lnconnect-clnrest`, they run as the `clightning`
user, like `lncli` runs as the `lnd` user. With
`services.clightning.plugins.clnrest.lnconnect.onion`, the `clightning` user gets its
own copy of the clnrest onion address for this. The option no longer needs the
operator role or explicit onion access for the operator user. The operator user needs
this access only to run `lnconnect-clnrest` as itself. `lnconnect-clnrest` reads the
admin rune and clnrest's cert only from regular files of the `clightning` user, also
when the operator runs it.

So as root, these commands can't read a file that only root can read, for example a
file that you pass to `bitcoin-cli -rpccookiefile`.
