#### Cashu mint service

The optional `services.cdk-mintd` service runs a Cashu mint using nixpkgs'
`cashu-cdk` package. Select local LND or Core Lightning for Lightning payments;
on-chain payments through a separate BDK wallet and Bitcoin Core are opt-in.
The module includes secret generation, systemd hardening, namespace isolation and
Tor onion access. With `services.backups`, it also stages consistent mint data and
signing secrets while the mint is stopped. Pending starts wait for staging to
finish; an explicit stop during staging cancels the pending restart.
A persistent initialization guard prevents recreating a lost database with the
old signing seed; restoration requires the spent-proof state as well as the seed.
See [Run a Cashu mint](../../cdk-mintd.md) for setup and recovery.
