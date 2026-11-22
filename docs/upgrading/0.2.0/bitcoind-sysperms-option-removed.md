#### bitcoind sysperms option removed

`services.bitcoind.sysperms` has been removed. Bitcoin Core 25.0 removed its `sysperms`
setting, so bitcoind ignored the option and logged a warning about it. Remove the
option from your configuration. To let the bitcoind group read the blocks dir, set
`services.bitcoind.dataDirReadableByGroup = true;`. This now also covers the files
that bitcoind creates while it runs. It needs POSIX ACL support on the filesystem of
the blocks dir, and it turns off bitcoind's wallet.
