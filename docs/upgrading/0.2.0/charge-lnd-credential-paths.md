#### Charge-LND credential paths

Charge-LND now reads the configured LND certificate and
`/run/lnd/charge-lnd.macaroon` directly, without a proxy data directory.
If you selected custom credentials with `--lnddir` in
`services.charge-lnd.extraFlags` and omitted either `--tlscert` or `--macaroon`,
add the missing credential path explicitly. Configurations already specifying
both paths, and default configurations, need no changes.

The old `/var/lib/charge-lnd/lnddir-proxy` tree is left behind on existing hosts.
It is no longer used and can be removed after upgrading.
