#### Backups include consistent copies of bitcoind wallets

Before each backup, the new `bitcoind-wallet-backup` unit asks bitcoind for a copy
of each loaded wallet in `/var/lib/bitcoind/wallet-backups`. A copy of the wallet
file itself can be torn, because bitcoind writes it while the backup runs. If a copy
fails, or bitcoind is starting or stopping, the `duplicity` unit fails after the
backup. See [bitcoind wallets](../../services.md#bitcoind-wallets) and the
[upgrade notes](../../upgrading/0.2.0/backups-include-copies-of-bitcoind-wallets.md).
