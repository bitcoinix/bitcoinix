#### Charge-LND credential paths

Charge-LND reads its certificate and macaroon directly, without staging them
under a synthetic mainnet directory. Users selecting custom credentials with
`--lnddir` should follow the [0.2.0 upgrade notes](../../upgrading/0.2.0/charge-lnd-credential-paths.md).
