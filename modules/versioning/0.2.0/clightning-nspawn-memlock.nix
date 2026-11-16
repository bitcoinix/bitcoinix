{ config, ... }:

{
  condition = config.boot.isNspawnContainer && config.services.clightning.enable;
  message = ''
    On the unstable package/system base, Core Lightning in systemd-nspawn
    needs memory-locking syscalls allowed for its signing keys.
    For custom systemd-nspawn containers, add
    `containers.<name>.extraFlags = [ "--system-call-filter=@memlock" ];`
    to the host configuration. Without this, lightning_hsmd aborts at startup.
    The bitcoinix container examples and test runner already allow these calls.
  '';
}
