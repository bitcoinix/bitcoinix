{ config, ... }:

{
  condition = config.services.lnd.enable && config.services.lnd.macaroons != {};
  message = ''
    Each custom lnd macaroon (`services.lnd.macaroons`, also used by BTCPay Server
    and charge-lnd) is now readable only by its `user`. Before, the user's primary
    group could read it too, which is `users` by default for a normal user. A
    program that reads the macaroon as another user now fails. Give it its own
    macaroon.
  '';
}
