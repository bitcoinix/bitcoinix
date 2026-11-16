{ config, lib, ... }:

with lib;
let
  cfg = config.services.charge-lnd;
  hasFlag = name: any (flag: flag == name || hasPrefix "${name}=" flag) cfg.extraFlags;
in
{
  condition = cfg.enable && hasFlag "--lnddir"
    && !(hasFlag "--tlscert" && hasFlag "--macaroon");
  message = ''
    charge-lnd now receives explicit --tlscert and --macaroon paths.
    If you use --lnddir in services.charge-lnd.extraFlags and omit either
    --tlscert or --macaroon, add the missing credential path explicitly:
    --lnddir no longer determines the credential paths.
  '';
}
