{ config, options, ... }:

let
  clightningRestUsed = options.services.clightning-rest.isDefined
    || options.services.rtl.cl-rest.isDefined;
in
{
  condition = !clightningRestUsed
    && config.services.backups.enable && config.services.clightning.enable;
  message = ''
    c-lightning-REST has been removed. If you previously ran it, the backups service
    no longer includes its data directory (default: /var/lib/clightning-rest).
  '';
}
