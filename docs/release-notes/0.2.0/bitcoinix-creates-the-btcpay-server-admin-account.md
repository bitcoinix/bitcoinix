#### bitcoinix creates the BTCPay Server admin account

BTCPay Server makes the first account that registers the server admin, so any local
user could take the admin account and the internal Lightning node until you registered.
When BTCPay Server has no admin, bitcoinix now creates the admin account `admin@localhost`
first, with the password in `$secretsDir/btcpayserver-admin-password`. Existing admins
stay, so check that they're yours. See the
[upgrade notes](../../upgrading/0.2.0/btcpay-server-admin-account.md).
