# BTCPay Server

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

BTCPay Server listens on localhost by default. Connect to it through an SSH tunnel, then
open `http://localhost:23000` in your browser:

```
ssh -L 23000:127.0.0.1:23000 operator@bitcoin-node
```

With `netns-isolation`, BTCPay Server listens in its own network namespace. Use the address
from `nodeinfo | jq -r .btcpayserver.local_address` instead, e.g. `169.254.1.24:23000`.

BTCPay Server makes the first account that registers the server admin, which can use the
internal Lightning node. So when BTCPay Server has no admin, the unit `btcpayserver-admin`
creates the admin account `admin@localhost` before BTCPay Server opens its port. BTCPay
Server then closes registration. Sign in with this account. The password is in
`$secretsDir/btcpayserver-admin-password`.
See: [Secrets dir](../configuration.md#secrets-dir)

An installation that already had an admin before bitcoinix 0.2.0 keeps it and gets no
`admin@localhost`. Sign in with your own account there.

You can change the account's email address and password in BTCPay Server. The secret file
keeps the first password.

## Check the admin accounts

Before bitcoinix 0.2.0, any local user could register first and become the admin until
you registered yours. So on an installation from before 0.2.0, check that each admin is
yours. Sign in, open Server Settings > Users and look at the users with the admin role.

If one isn't yours, or if you found registration closed before you registered, someone
else had admin access. An admin can install plugins that run as the `btcpayserver` user
and can use your Lightning node. So treat the node as compromised:

1. Stop BTCPay Server with `systemctl stop btcpayserver`.
2. Move the funds of the Lightning node and of the wallets on this node to a new wallet
   that this node doesn't control.
3. Set up the node again.

## Lightning backend

`services.btcpayserver.lightningBackend` connects BTCPay Server to the node's lnd or
Core Lightning. The two backends give BTCPay Server different access.

With `lnd`, BTCPay Server gets its own macaroon, `services.lnd.macaroons.btcpayserver`
(see [Custom macaroons](lnd.md#custom-macaroons)). It can read the node's state and create
invoices and addresses. It can't send funds or open or close channels, so BTCPay
Server can't make Lightning payouts.

With `clightning`, BTCPay Server has full control of the Lightning node, including its
funds. It joins the clightning group and uses lightningd's RPC socket `lightning-rpc`,
which allows every method. So BTCPay Server can pay invoices (`pay`, `xpay`), send
on-chain funds (`withdraw`), open and close channels (`fundchannel`, `close`) and start
plugins (`plugin`), which run as the clightning user. With clnrest enabled, the group
can also read clnrest's admin rune. A bug in BTCPay Server, a malicious BTCPay plugin or
a stolen admin session can drain the node. The pinned BTCPay Server 2.4.7 uses
BTCPayServer.Lightning 1.7.14, whose Core Lightning client connects only over this
socket or TCP and can't use runes. So bitcoinix can't give it restricted access yet.

The backend limits only what BTCPay Server can do with the Lightning node. A hot wallet
that you create in BTCPay Server keeps its keys on the node, so BTCPay Server can spend it
with either backend.

Use `lnd` when you want BTCPay Server limited, for example when its web interface is
reachable from the internet. bitcoinix turns on Core Lightning for BTCPay Server only
while it's the backend. So if your Core Lightning has channels, set
`services.clightning.enable = true` before you switch, or close the channels first.
Otherwise the switch stops Core Lightning, and nothing watches its channels. Both
daemons use port 9735 by default, so also give lnd another port, for example
`services.lnd.port = 9736;`.
