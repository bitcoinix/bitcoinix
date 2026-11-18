#### Backups include copies of bitcoind wallets

Before each backup, the new `bitcoind-wallet-backup` unit asks a local bitcoind for a
consistent copy of each loaded wallet. The `duplicity` unit now also fails when a
copy fails, or when bitcoind is starting or stopping. It still backs up all other
files first. If a backup fails, check `journalctl -u bitcoind-wallet-backup`. See
[bitcoind wallets](../../services.md#bitcoind-wallets).
