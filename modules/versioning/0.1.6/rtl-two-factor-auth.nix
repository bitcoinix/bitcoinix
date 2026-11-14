{ config, ... }:

{
  condition = config.services.rtl.enable;
  message = ''
    RTL now keeps the two-factor authentication that you set up in its web
    interface across restarts. Before, each restart turned it off. To turn it
    off without the authenticator, delete RTL-Config.json in RTL's data dir and
    restart RTL. RTL-Config.json, which holds the 2FA secret, is now readable
    only by RTL's user, not by group rtl.
  '';
}
