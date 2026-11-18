#### Backups leave out the Lightning channel databases

The backups service no longer includes lnd's `graph` directory, which holds
`channel.db`, or Core Lightning's `lightningd.sqlite3`. It copied these files while
the daemons wrote them. A node that runs from an outdated copy can broadcast a
revoked channel state, and the peer can then take all funds in that channel.

Backups made before this change still contain these files. Never restore them.
To recover Lightning funds, use the files that
[Lightning channel databases](../../services.md#lightning-channel-databases) lists.
For a copy of the Core Lightning database that's always current, use
[database replication](../../services.md#core-lightning-database-replication).
