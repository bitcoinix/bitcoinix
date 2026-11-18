#### NBXplorer RPC password permissions

NBXplorer's bitcoind RPC password (`bitcoin-rpcpassword-btcpayserver` in the
[secrets dir](../../configuration.md#secrets-dir)) is now readable only by NBXplorer's
user (`services.nbxplorer.user`), with mode `0400`. Before, bitcoind's user and
NBXplorer's group could read it too. BTCPay Server is in that group to read
NBXplorer's API cookie, so it could read the password. BTCPay Server still reads
the cookie.

If a program reads the password as another user, give the program its own RPC user
in `services.bitcoind.rpc.users`. If you manage the secret files outside bitcoinix,
for example with `nix-bitcoin.secretsSetupMethod = "manual"`, make NBXplorer's user the
owner of the file and set its mode to `0400`.

If you think that BTCPay Server was compromised, replace the password. With a local
bitcoind and `nix-bitcoin.generateSecrets = true`, delete the password file and run
`systemctl restart setup-secrets`. Then run `systemctl restart bitcoind nbxplorer`.
