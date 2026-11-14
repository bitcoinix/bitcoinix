{ config, ... }:

{
  condition = config.services.lnd.enable;
  message = ''
    lnd now restarts automatically after a clean exit, including `lncli stop`.
    To keep lnd stopped, use `systemctl stop lnd` instead. Update maintenance
    scripts that rely on `lncli stop` leaving lnd down.
  '';
}
