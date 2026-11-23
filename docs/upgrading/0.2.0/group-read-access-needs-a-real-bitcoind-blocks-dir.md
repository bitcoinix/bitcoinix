#### Group read access needs a real bitcoind blocks dir

With `services.bitcoind.dataDirReadableByGroup` on mainnet, bitcoind no longer changes
the permissions of the blocks dir (`blocks` in the data dir) when it's a symlink. Members
of the bitcoind group can write to the data dir, so they could replace `blocks` with a
symlink to other files of the bitcoind user and make bitcoind give the group access to
them. The new `bitcoind-group-read` service, which sets up the group's access before
each start of bitcoind, now logs a warning and leaves the target alone. On regtest, the
blocks dir wasn't covered before. Now it is, if neither `regtest` nor `regtest/blocks`
is a symlink.

If your blocks dir is a symlink, for example to a dir on a second disk, the group can't
read the block files that bitcoind creates from now on. Replace the symlink with a dir,
or with a bind mount of the dir on the second disk. That dir and all entries in it must
belong to the bitcoind user and group (`bitcoin` by default). The service leaves an entry of
another user or group alone, so the bitcoind group can't read it, and logs a warning on
each start. So don't mount the root of a filesystem there, which can hold a root-owned
`lost+found`.

A mount point can't be a symlink. Stop bitcoind and run `rm /var/lib/bitcoind/blocks`.
Then deploy a config with a mount like the one below, and start bitcoind.

```nix
fileSystems."/var/lib/bitcoind/blocks" = {
  device = "/mnt/disk2/blocks";
  fsType = "none";
  options = [ "bind" ];
};
```
