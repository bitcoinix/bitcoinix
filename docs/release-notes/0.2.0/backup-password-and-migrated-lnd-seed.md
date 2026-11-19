#### Backup password and migrated lnd seed

With `nix-bitcoin.generateSecrets`, the backups include the password that decrypts them,
`backup-encryption-password` in the secrets dir. Keep a copy of it off the node. If you
migrated lnd from another node, the `lnd-seed-mnemonic` on the node may not hold the
seed of your wallet. See
[Migrate existing services to bitcoinix](../../configuration.md#migrate-existing-services-to-bitcoinix).
