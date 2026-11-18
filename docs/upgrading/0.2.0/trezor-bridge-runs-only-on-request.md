#### Trezor Bridge runs only on request

The Trezor Bridge (`trezord`) no longer runs. HWI and `trezorctl` open the device
directly and don't need it. The bridge couldn't open the device before, since its
user wasn't in group `hardware-wallets`. To run it for apps that use it, set:
```nix
services.hardware-wallets.trezorBridge = true;
```
The bridge serves an HTTP API without authentication on `127.0.0.1:21325`. Every
local user and service can then use the Trezor through it. For example, they can
read its public keys while it's unlocked, which reveals the addresses of its
wallets. Signing still needs a confirmation on the device. If you set
`services.trezord.enable = true` yourself instead and don't give trezord the group,
evaluation warns that the bridge can't open the device.
