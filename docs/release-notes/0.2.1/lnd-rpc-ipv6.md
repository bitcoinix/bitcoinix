#### IPv6 addresses for LND RPC

`services.lnd.rpcAddress` accepts IPv6 addresses with or without brackets.
LND, `lncli`, macaroon creation, charge-lnd and Unbeholden LNURL use the same
gRPC endpoint, including when the certificate names a wildcard address.
Empty hosts, addresses containing whitespace, and malformed brackets fail evaluation.
[Upgrading a node with an empty RPC host](../../upgrading/0.2.1/lnd-empty-rpc-address.md)
