# Using services

How to reach and run the services on your node. The service guides assume the
`secure-node.nix` preset, which adds Tor onion services, `nodeinfo` and the `operator`
user, unless they say otherwise.

## Node administration

- [Nodeinfo](service/nodeinfo.md): service addresses, versions and node IDs.
- [SSH](service/sshd.md): connect and deploy through the node's onion service.
- [Backups](service/backups.md): node data, Bitcoin wallets and Lightning recovery files.

### Managing services

NixOS uses the [systemd](https://wiki.archlinux.org/title/systemd) service manager.

Usage:
```shell
# Show service status
systemctl status bitcoind

# Show the last 100 log messages
journalctl -u bitcoind -n 100
# Show all log messages since the last system boot
journalctl -b -u bitcoind

# These commands require root permissions
systemctl stop bitcoind
systemctl start bitcoind
systemctl restart bitcoind

# Show the service definition
systemctl cat bitcoind
# Show all service parameters
systemctl show bitcoind
```

## Wallets and apps

- [electrs and Fulcrum](service/electrs.md): connect Electrum wallets through Tor.
- [RTL](service/rtl.md): access the web interface and manage backend credentials.
- [BTCPay Server](service/btcpayserver.md): sign in and choose a Lightning backend.
- [Unbeholden LNURL](service/unbeholden-lnurl.md): receive payments with Lightning Addresses.
- [Unbeholden Wallet](service/unbeholden-wallet.md): connect the watch-only browser wallet.
- [Cashu mint](cdk-mintd.md): issue ecash backed by Lightning or optional on-chain payments.
- [ZEUS](service/zeus.md): connect to LND or Core Lightning over Tor or WireGuard.
- [Trezor](service/trezor.md): initialize and use a hardware wallet with HWI.

## Lightning nodes

- [LND](service/lnd.md): create, manage and revoke custom macaroons.
- [Core Lightning](service/clightning.md): configure plugins and database replication.
