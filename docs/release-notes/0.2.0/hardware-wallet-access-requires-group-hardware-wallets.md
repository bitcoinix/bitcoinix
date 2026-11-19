#### Hardware wallet access requires group hardware-wallets

The Ledger and Trezor udev rules of `services.hardware-wallets` no longer let the
user of the active local session use the device, so only members of group
`hardware-wallets` can use it. The Ledger rule now matches every Ledger device, not
only product `0001`. See
[Upgrading to config version 0.2.0](../../upgrading/0.2.0/hardware-wallet-access-requires-group-hardware-wallets.md).
