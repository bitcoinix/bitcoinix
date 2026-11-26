# electrs and Fulcrum

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

Electrum wallets can connect to your electrs (or Fulcrum) server through its onion
service, which the `secure-node.nix` and `enable-tor.nix` presets create.

<a id="requirements-android"></a>

## Android requirements
* [Orbot](https://guardianproject.info/apps/org.torproject.android/) from F-Droid or [Google Play](https://play.google.com/store/apps/details?id=org.torproject.android)
* [Electrum](https://electrum.org/#download) from the direct download or [Google Play](https://play.google.com/store/apps/details?id=org.electrum.electrum)

<a id="requirements-desktop"></a>

## Desktop requirements
* [Tor](https://support.torproject.org/little-t-tor/), listening on its default SOCKS port 9050
* [Electrum](https://electrum.org/#download)

## Connect your wallet

1. Enable electrs in your configuration:
    ```nix
    services.electrs.enable = true;
    ```
    For Fulcrum, set `services.fulcrum.enable = true` and use `.fulcrum` instead of
    `.electrs` below.

2. Deploy your configuration.

3. Get the electrs onion address, in the format `<onion-address>:<port>`:
    ```
    nodeinfo | jq -r .electrs.onion_address
    ```

4. Connect to electrs

    Make sure Tor is running on your desktop or as Orbot on Android.

    On your desktop
    ```
    electrum --oneserver -s "<electrs onion address>:t" -p socks5:127.0.0.1:9050
    ```

    On Android, open the network settings and set:
    - Proxy: SOCKS5, host `127.0.0.1`, port `9050`
    - Auto-connect: off, one-server mode: on
    - Server: `<electrs onion address>:t`
