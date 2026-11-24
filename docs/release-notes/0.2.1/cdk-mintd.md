#### Cashu mint service

The optional `services.cdk-mintd` service runs a Cashu mint using nixpkgs'
`cashu-cdk` package. Select local LND or Core Lightning for Lightning payments;
on-chain payments through a separate BDK wallet and Bitcoin Core are opt-in.
The module includes secret generation, systemd hardening, namespace isolation and
Tor onion access. With `services.backups`, it also stages consistent mint data and
signing secrets while the mint is stopped, then restarts it before uploading.
See [Run a Cashu mint](../../cdk-mintd.md) for setup and recovery.
