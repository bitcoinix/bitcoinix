#### Group read access needs a real bitcoind blocks dir

With `services.bitcoind.dataDirReadableByGroup` on mainnet, the bitcoind service no
longer changes the permissions of the blocks dir (`blocks` in the data dir) when it's a
symlink. Members of the bitcoind group can write to the data dir, so they could replace
`blocks` with a symlink to other files of the bitcoind user and make the service give
the group access to them. The service now logs a warning and leaves the target alone.
On regtest, the service didn't cover the blocks dir before. Now it does, if neither
`regtest` nor `regtest/blocks` is a symlink.

If your blocks dir is a symlink, for example to a dir on a second disk, the group can't
read the block files that bitcoind creates from now on. Replace the symlink with a dir,
or with a bind mount of the dir on the second disk. All entries in that dir must belong
to the bitcoind user and group (`bitcoin` by default), so don't mount the root of a
filesystem there, which can hold a root-owned `lost+found`.

A mount point can't be a symlink. Stop bitcoind and run `rm /var/lib/bitcoind/blocks`.
Then deploy a config with a mount like the one below, and start bitcoind.

```nix
fileSystems."/var/lib/bitcoind/blocks" = {
  device = "/mnt/disk2/blocks";
  options = [ "bind" ];
};
```
