#### Hardware wallet access requires group hardware-wallets

With `services.hardware-wallets.ledger` or `trezor` enabled, the Ledger and Trezor
devices that its udev rules match are now available only to members of group
`hardware-wallets` (`services.hardware-wallets.group`). The operator user is in that
group. Before, systemd's `70-uaccess.rules` also gave these devices to the user of
the active local session, and the Trezor rules added the `uaccess` tag themselves.
The rules now remove that tag. The Ledger rules now match every Ledger device that
systemd lists: all of USB vendor `2c97`, and the HW.1 and early Nano IDs of vendor
`2581`. Before, they matched only product `0001`, so the group didn't get other Ledger
models and firmware versions. To give another user access,
add it to the group:
```nix
users.users.<name>.extraGroups = [ "hardware-wallets" ];
```
A device that's plugged in while you deploy keeps the session user's access until
you unplug it.
