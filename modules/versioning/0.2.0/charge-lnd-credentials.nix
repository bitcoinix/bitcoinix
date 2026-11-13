{ config, lib, ... }:

with lib;
{
  condition = config.services.charge-lnd.enable && any
    (flag: flag == "--lnddir" || hasPrefix "--lnddir=" flag)
    config.services.charge-lnd.extraFlags;
  message = ''
    charge-lnd now receives explicit --tlscert and --macaroon paths.
    If you use --lnddir in services.charge-lnd.extraFlags to select custom
    credentials, replace it with --tlscert and --macaroon: --lnddir no
    longer determines the credential paths.
  '';
}
