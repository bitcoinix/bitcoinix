#### bitcoind data dir no longer writable by its group

The bitcoind data dir (`services.bitcoind.dataDir`, `/var/lib/bitcoind` by default)
now has mode `0750` instead of `0770`. Before, every member of the bitcoind group
(`services.bitcoind.group`, `bitcoin` by default) could create, rename and delete
entries in it. The group holds the operator user (with `nix-bitcoin.operator.enable`)
and the users that you add to it.

The deployment sets the new mode with tmpfiles, which doesn't follow a symlink. So if
the data dir is a symlink, give its target the owner and mode that tmpfiles would set,
with `chown bitcoin:bitcoin` and `chmod 750` on the target. Use your
`services.bitcoind.user` and `services.bitcoind.group` if you changed them.

Group members can still use `bitcoin-cli`, read the RPC cookie and read the files
they could read before, also the blocks dir with
`services.bitcoind.dataDirReadableByGroup`. A script that writes to the data dir as a
group member now fails. Run it as the bitcoind user (`services.bitcoind.user`,
`bitcoin` by default) or as root.

bitcoind creates its files as the bitcoind user. To list the entries in the data dir
that another user created, run this as root. Use your `services.bitcoind.dataDir` and
`services.bitcoind.user` if you changed them.

```shell
find /var/lib/bitcoind/ ! -user bitcoin
```

Stop bitcoind and move each entry that you didn't create yourself out of the data dir
before you start bitcoind again.
