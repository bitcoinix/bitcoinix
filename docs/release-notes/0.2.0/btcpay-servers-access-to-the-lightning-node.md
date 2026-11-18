#### BTCPay Server's access to the Lightning node

With `services.btcpayserver.lightningBackend = "clightning"`, BTCPay Server has full
control of the Lightning node, including its funds. With `lnd`, it gets a restricted
macaroon. See [Lightning backend](../../services.md#lightning-backend).
