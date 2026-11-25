#### Empty LND RPC host

If you set `services.lnd.rpcAddress` to `""` or `"[]"`, choose the address LND
should listen on. Remove the setting to use the default loopback address
(`127.0.0.1`). Set `"::"` to keep the previous IPv6-only wildcard listener, or
`"0.0.0.0"` for an IPv4-only wildcard listener. If you supply LND's TLS
certificate yourself, include the chosen IP address in its subject alternative
names so local gRPC clients can verify it. In OpenSSL notation, the entries
for the two wildcards are `IP:::` and `IP:0.0.0.0`, respectively.
