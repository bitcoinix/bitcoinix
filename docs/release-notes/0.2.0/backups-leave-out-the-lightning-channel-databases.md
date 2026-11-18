#### Backups leave out the Lightning channel databases

The backups service copied the channel databases of lnd and Core Lightning while the
daemons wrote them. Such a copy can be torn, and a node that runs from an outdated
copy can lose all funds in its channels. The backup now leaves these databases out.
It still has the files that recovery needs: the lnd seed and `channel.backup`, and
Core Lightning's `hsm_secret` and `emergency.recover`. See
[Backups](../../services.md#backups) and the
[upgrade notes](../../upgrading/0.2.0/backups-leave-out-the-lightning-channel-databases.md).
