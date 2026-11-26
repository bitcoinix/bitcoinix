# Trezor

Initialize a Trezor for the Bitcoin Hardware Wallet Interface (HWI) and use it
with your node.

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

1. Enable Trezor support in your configuration:
    ```nix
    services.hardware-wallets.trezor = true;
    ```
    This installs `hwi`, `trezorctl` and `lsusb`, and adds udev rules that give group
    `hardware-wallets` access to the device. Only members of that group can use it,
    unless you run the Trezor Bridge (see below). The `operator` user is in that group.
    Hardware wallets require the bitcoind wallet, so `services.bitcoind.disablewallet`
    must stay unset or `false`.

2. Deploy your configuration.

3. Plug in your Trezor and check that your node recognizes it:

    ```
    ssh operator@bitcoin-node
    lsusb
    ```

4. If your Trezor's firmware is outdated, update it:

    ```
    trezorctl firmware update
    ```
    Keep your recovery seed at hand: a firmware update can wipe the device. See
    [Trezor's firmware guide](https://trezor.io/learn/a/update-trezor-device-firmware)
    for the bootloader mode of your model.

5. If your Trezor is not yet initialized, set it up with a PIN:

    ```
    trezorctl device setup -p
    ```

6. Find your Trezor:

    ```
    hwi enumerate
    ```
    A Trezor One asks for its PIN through HWI:
    ```
    hwi -t trezor -d <path from previous command> promptpin
    hwi -t trezor -d <path> sendpin <number positions for the PIN as displayed on your device's screen>
    hwi enumerate
    ```

7. Follow HWI's guide on [using Bitcoin Core with hardware wallets](https://hwi.readthedocs.io/en/latest/examples/bitcoin-core-usage.html) to use your Trezor with `bitcoin-cli` on your node.

The Trezor Bridge (`trezord`) doesn't run by default, since HWI and `trezorctl` don't
need it. To run it for apps that use it, set `services.hardware-wallets.trezorBridge = true;`.
The bridge serves an HTTP API without authentication on `127.0.0.1:21325`, so every
local user and service can then use the Trezor through it.
