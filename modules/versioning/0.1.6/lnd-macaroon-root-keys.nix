{ config, ... }:

{
  condition = config.services.lnd.enable;
  message = ''
    Each custom lnd macaroon (`services.lnd.macaroons`, also used by BTCPay Server
    and charge-lnd) now has its own root key, with an ID from 7953919891889717248
    to 7954201366866427903 (0x6e62000000000000 to 0x6e62ffffffffffff). Each time
    lnd starts, bitcoinix deletes the root key of every ID in this range that no
    configured macaroon uses. Before deploying, check that `lncli listmacaroonids`
    lists no ID in this range. Copies of custom macaroons created before this
    change use root key 0 and stay valid. Each lnd start now uses the admin
    macaroon over gRPC, also without custom macaroons, so `no-macaroons` isn't
    supported.
  '';
}
