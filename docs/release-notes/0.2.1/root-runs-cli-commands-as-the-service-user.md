#### Root runs CLI commands as the service user

`bitcoin-cli` now reads the config that bitcoinix generates from the Nix store, and
not the copy in the data dir. When root runs `bitcoin-cli`, it runs as the `bitcoin`
user. With the `bitcoind-remote.nix` preset, the credentials for the remote node are
now in `/run/bitcoind/.cookie` and not in `bitcoin.conf`.

So as root, these commands can't read a file that only root can read, for example a
file that you pass to `bitcoin-cli -rpccookiefile`.
