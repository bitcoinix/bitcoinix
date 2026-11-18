{ config, ... }:

let
  cfg = config.services.hardware-wallets;
in
{
  # A config that sets services.trezord.enable itself keeps the bridge, and a
  # warning tells it to set trezorBridge.
  condition = cfg.trezor && !config.services.trezord.enable;
  message = ''
    The Trezor Bridge (trezord) no longer runs. HWI and trezorctl open the
    device directly and don't need it. To run it, set
    `services.hardware-wallets.trezorBridge = true`. Every local user and
    service can then use the Trezor through it.
  '';
}
