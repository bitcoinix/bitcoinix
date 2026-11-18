{ config, ... }:

let
  cfg = config.services.hardware-wallets;
in
{
  condition = cfg.ledger || cfg.trezor;
  message = ''
    The Ledger and Trezor devices that the `services.hardware-wallets` udev
    rules match are now available only to members of group `${cfg.group}`.
    Before, systemd also gave them to the user of the active local session.
    To give another user access, add it to group `${cfg.group}`. A device
    that's plugged in while you deploy keeps the session user's access until
    you unplug it.
  '';
}
