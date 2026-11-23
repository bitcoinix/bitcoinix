#### Signet and testnet4

Set `services.bitcoind.network` to `"signet"` or `"testnet4"` to deploy on a
public test network. Evaluation reports incompatible services and plugins
before deployment. Switching an existing node in place reuses several service
databases. Read the [network-switch warning](../../configuration.md#bitcoin-network)
before changing this option.

New LND regtest wallets are initialized with regtest chain parameters.
