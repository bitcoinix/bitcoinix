# Run a Cashu mint

[CDK Mintd](https://github.com/cashubtc/cdk/tree/v0.18.3/crates/cdk-mintd) issues
Cashu ecash backed by your local LND or Core Lightning node. The service uses
`cdk-mintd` from nixpkgs' `cashu-cdk` package.

```nix
services.cdk-mintd = {
  enable = true;
  backend = "lnd"; # or "clightning"
  url = "https://mint.example.org";
  settings.mint_info.name = "My Cashu mint";
};
```

The selected Lightning service is enabled automatically. It needs funded channels
and inbound liquidity to send and receive payments. LND gives the mint a dedicated
macaroon limited to invoices, payment routing and payment status. Core Lightning
uses its Unix RPC socket: the mint joins the `clightning` group and has full RPC
access, including the ability to spend funds and start plugins.

Before changing backends, settle outstanding payments and keep the old node
enabled explicitly if it still has channels. If you run both nodes, give them
different Lightning ports; both default to 9735.

## Access

The HTTP API listens on `127.0.0.1:8085` by default. Put a reverse proxy with HTTPS
in front of it and set `url` to the address wallets will use. The module opens no
firewall ports. With namespace isolation, use the address shown by
`nodeinfo | jq -r '.["cdk-mintd"].local_address'` as the proxy target.
The mint namespace can reach LND when selected and Bitcoin Core when on-chain
support is enabled; Core Lightning uses a Unix socket.

For Tor access, set `nix-bitcoin.onionServices.cdk-mintd.enable = true;` and use
the resulting `http://<address>.onion` URL. The onion service exposes port 80.
The Tor preset restricts the mint to local connections; it needs no external
payment API or chain server.

Check the service with `journalctl -u cdk-mintd` and query its HTTP `/v1/info`
endpoint. See [the options](options.md) for listen addresses, paths and settings.

## Optional on-chain payments

Lightning-only operation is the default. To also accept and send on-chain payments:

```nix
services.cdk-mintd.onchain.enable = true;
```

This creates a separate BDK wallet, using the local Bitcoin Core RPC for scanning
and broadcasting. It does not use the Lightning node's on-chain wallet. The
Bitcoin Core node must be unpruned. CDK 0.18.3 supports mainnet, signet and regtest
here, but not testnet4. Deposits require three confirmations by default; configure
`services.cdk-mintd.settings.bdk.num_confs` to change this.

When adding on-chain support **after the mint has already started**, also set
`services.cdk-mintd.onchain.allowNewWallet = true;` for the first deployment.
After the wallet starts successfully, set it back to `false`. New mints create
their first BDK wallet without this flag. A missing wallet database on a later
start is an error, rather than a reason to silently create a replacement.

## Secrets, configuration and recovery

With `nix-bitcoin.generateSecrets`, the module generates `cdk-mintd-seed` in
`nix-bitcoin.secretsDir` and, when needed, `cdk-mintd-bdk-mnemonic`. Otherwise
provide these through your [secrets setup](configuration.md). You can point
`seedFile` and `onchain.mnemonicFile` at other absolute paths readable by the
service user. Use string paths, not Nix path literals that copy files to the store.
The signing seed is raw text, not hex-decoded; preserve every byte, including its
trailing newline. The BDK secret is a separate BIP39 mnemonic.

CDK stores configuration in its SQLite database. Before the first start the
module runs `config init --new-mint`; when the generated Nix configuration
changes, it runs `config apply`. It records the imported document in
`dataDir/nix-config`. Configure metadata and fees through `settings`; direct
changes through CDK's management tools can be replaced by a later Nix deployment.
The module manages backend connections and signing settings. Keep secrets out of
`settings`, which is world-readable in the Nix store.

Preserve the entire `dataDir` (default `/var/lib/cdk-mintd`) and both secrets.
The mint database records spent proofs and outstanding obligations: a seed alone
cannot recover it, and an outdated database can accept already-spent ecash.
**The mint data directory is not included in `services.backups` automatically.**
Stop the mint before taking a consistent copy of the complete directory and
secrets, and keep the Lightning backend's recovery data separately.

Restore the BDK wallet database together with its mnemonic. For last-resort
mnemonic-only recovery, follow CDK's
[BDK recovery guidance](https://github.com/cashubtc/cdk/blob/v0.18.3/crates/cdk-mintd/README.md#adding-bdk-to-an-existing-mint),
including `settings.bdk.wallet_rescan_from_height` and a temporary
`onchain.allowNewWallet`. Fresh BDK wallets otherwise begin scanning at the current
chain tip and miss historical deposits.

Importing an existing standalone CDK mint requires its original signing source
and database and CDK's explicit migration procedure. The module's automatic
new-mint initialization refuses a database with existing mint identity or keysets.
