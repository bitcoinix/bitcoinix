#### Group read access to new bitcoind block files

With `services.bitcoind.dataDirReadableByGroup`, the bitcoind group can now read the
block files and block index files that bitcoind creates while it runs. Before, the
group could read only the files that existed when bitcoind started, and none on
regtest. The bitcoind service now sets a default ACL on the blocks dir. This needs
POSIX ACL support on the filesystem of the blocks dir. Without it, bitcoind still starts
and logs a warning. If the blocks dir is a symlink, the group can't read new block files
anymore. The `services.bitcoind.sysperms` option has been removed, because Bitcoin Core
ignores it. See the upgrade notes on
[a symlinked blocks dir](../../upgrading/0.2.0/group-read-access-needs-a-real-bitcoind-blocks-dir.md)
and [the removed option](../../upgrading/0.2.0/bitcoind-sysperms-option-removed.md).
