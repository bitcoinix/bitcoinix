#### BTCPay Server admin account

BTCPay Server makes the first account that registers the server admin, which can use
the internal Lightning node. Before, any local user could register first and take that
account until you registered yours. When BTCPay Server has no admin, bitcoinix now
creates the admin account `admin@localhost` before BTCPay Server opens its port. Its
password is in the new secret `$secretsDir/btcpayserver-admin-password`.

- If your BTCPay Server already has an admin, bitcoinix keeps it and doesn't create
  `admin@localhost`. Check that each admin is yours.
  [Check the admin accounts](../../services.md#check-the-admin-accounts) says how, and
  what to do if one isn't. This matters most if BTCPay Server ran for a while before
  you registered, or if you found registration closed.
- If it has no admin yet, sign in as `admin@localhost` instead of registering. See
  [Connect to BTCPay Server](../../services.md#connect-to-btcpay-server).
- If you supply your secrets yourself instead of with `nix-bitcoin.generateSecrets`,
  put a password in `btcpayserver-admin-password` before you deploy. With krops, the
  `deploy` and `krops-deploy` commands of the deployment shell run `generate-secrets`,
  which creates it.
