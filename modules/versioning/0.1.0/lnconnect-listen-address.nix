{ config, ... }:

{
  condition = with config.services;
    (lnd.enable && lnd.lndconnect.enable && !lnd.lndconnect.onion
      && lnd.restAddress == "127.0.0.1")
    || (clightning.plugins.clnrest.enable && clightning.plugins.clnrest.lnconnect.enable
      && !clightning.plugins.clnrest.lnconnect.onion
      && clightning.plugins.clnrest.address == "127.0.0.1");
  message = ''
    Enabling `lndconnect` or `lnconnect` without `onion` no longer sets the REST
    listen address to 0.0.0.0, so the lnd/clnrest REST APIs now listen on localhost only.
    To connect over your LAN or VPN, set the address yourself. See docs/services.md,
    "Connecting without Tor or WireGuard".
  '';
}
