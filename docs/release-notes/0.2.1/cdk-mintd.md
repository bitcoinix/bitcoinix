#### Cashu mint service

The optional `services.cdk-mintd` service runs a Cashu mint using nixpkgs'
`cashu-cdk` package. Select local LND or Core Lightning for Lightning payments;
on-chain payments through a separate BDK wallet and Bitcoin Core are opt-in.
The module includes secret generation, systemd hardening, namespace isolation and
Tor onion access. See [Run a Cashu mint](../../cdk-mintd.md) for setup and recovery.
