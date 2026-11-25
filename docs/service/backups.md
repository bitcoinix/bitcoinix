# Backups

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

`services.backups` backs up node data with duplicity, to `/var/lib/localBackups` by
default. See the Backups section in
[`examples/configuration.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/examples/configuration.nix)
and the [module](https://github.com/bitcoinix/bitcoinix/blob/master/modules/backups.nix)
for the options.

The backup includes the data directories of bitcoind, lnd, Core Lightning, NBXplorer
and BTCPay Server, dumps of the BTCPay Server databases, `/var/lib/tor`,
`/var/lib/nixos` and, with `nix-bitcoin.generateSecrets`, the secrets directory.
It leaves out the mainnet, signet and testnet4 blockchains and their indexes
unless `with-bulk-data` is set. This also covers networks previously used on the node.

## Lightning channel databases

The backup never includes lnd's `graph` directory, which holds `channel.db`, or
Core Lightning's `lightningd.sqlite3` in any network directory. It also excludes
the SQLite files set by `services.clightning.wallet` and each network's replica
at the configured replication destination. The daemons write these files while
the backup runs, so a copy can be torn. A copy is also outdated as soon as a channel changes.
A node that runs from an outdated channel database can broadcast a revoked channel
state, and the peer can then take all funds in that channel. Never restore a copied
channel database. Backups made before bitcoinix 0.2.0 contain them.

To recover Lightning funds, use these files from the backup instead. Both ways ask
each peer to force close its channel, so they need the peer to be reachable. They
get back settled funds, but not funds in pending payments.

- lnd: the seed `/var/lib/lnd/lnd-seed-mnemonic` and the static channel backup
  `/var/lib/lnd/chain/bitcoin/mainnet/channel.backup`.
  Restore the seed on a node where lnd hasn't created a wallet yet, and bitcoinix
  creates the wallet from it. Keep the restored `channel.backup` outside lnd's data
  directory, because lnd replaces its own copy with the channels it knows. Then run
  `lncli restorechanbackup --multi_file <path to channel.backup>`. See lnd's
  [recovery guide](https://github.com/lightningnetwork/lnd/blob/master/docs/recovery.md),
  also for recovering on-chain funds.
- Core Lightning: `hsm_secret` and `emergency.recover` in `/var/lib/clightning/bitcoin/`.
  Restore both to that directory, owned by the `clightning` user, before Core Lightning
  first starts on the node. Then run `lightning-cli emergencyrecover`. See Core
  Lightning's [recovery guide](https://docs.corelightning.org/docs/recovery).

For a copy of the Core Lightning database that's always current, use
[database replication](clightning.md#core-lightning-database-replication). When Core Lightning
stores its database in PostgreSQL, don't add it to
`services.backups.postgresqlDatabases`. Its dump is an outdated copy of the channel
state too.

## bitcoind wallets

Before each backup, the `bitcoind-wallet-backup` unit asks bitcoind for a consistent
copy of each loaded wallet. It writes them to `/var/lib/bitcoind/wallet-backups`
as `wallet-<sha256 of the wallet name>.dat`, and `wallet-names.json` there maps each
file to its wallet name. bitcoinix manages this directory and replaces the copies
before each backup, so don't keep other files there. The backup also has the wallet
files themselves, but a copy of a loaded wallet's file can be torn. Restore a loaded
wallet from its copy, for example with `bitcoin-cli restorewallet <name> <copy>`.

When bitcoind doesn't run during a backup, there are no copies, and the wallet files
are consistent. If a copy fails, or bitcoind is starting or stopping, the `duplicity`
unit fails after the backup. With the `bitcoind-remote.nix` preset, the wallets are
on the other node, and the backup makes no copies.

## Cashu mint

When `cdk-mintd` is enabled, the backup briefly stops it to stage its complete data
and signing secrets in `/var/lib/cdk-mintd-backup/current`. A previously running
or starting mint is queued to restart before uploading; a stopped mint stays
stopped unless a new start is requested during staging. Duplicity includes
the snapshot and excludes live mint databases. A stop during staging cancels a
pending mint restart. Copy failures still back up the other services, then fail
the backup. See [mint backup and recovery](../cdk-mintd.md#automated-backups)
for the snapshot layout, custom secrets and the risks of restoring outdated spent-proof state.
