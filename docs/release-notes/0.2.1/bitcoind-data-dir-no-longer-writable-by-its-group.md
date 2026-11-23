#### bitcoind data dir no longer writable by its group

The bitcoind data dir now has mode `0750` instead of `0770`, like the Core Lightning
data dir. Members of the bitcoind group, like the operator user, can still use
`bitcoin-cli` and read the files they could read before, but they can't write to the
data dir. See
[Upgrading to config version 0.2.1](../../upgrading/0.2.1/bitcoind-data-dir-no-longer-writable-by-its-group.md).
