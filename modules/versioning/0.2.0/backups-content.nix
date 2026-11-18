{ config, ... }:

{
  condition = config.services.backups.enable;
  message = ''
    The backups service no longer includes the Lightning channel databases: lnd's
    `graph` directory with `channel.db`, and Core Lightning's `lightningd.sqlite3`.
    A node that runs from an outdated copy of them can lose all funds in its
    channels. Backups made before this change still contain them. Never restore
    them. The backup still has the files that recovery needs: the lnd seed and
    `channel.backup`, and Core Lightning's `hsm_secret` and `emergency.recover`.
    Before each backup, the new `bitcoind-wallet-backup` unit also copies each
    loaded bitcoind wallet. The `duplicity` unit now also fails when a copy fails,
    or when bitcoind is starting or stopping.
  '';
}
