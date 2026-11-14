{ config, ... }:

{
  condition = config.services.fulcrum.enable;
  message = ''
    Fulcrum 1.9.0 has changed its database format.
    The database update happens automatically and instantly on deployment,
    but you can't switch back to an older Fulcrum version afterwards.
  '';
}
