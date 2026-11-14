{ config, ... }:

{
  condition = config.services.charge-lnd.enable;
  message = ''
    The charge-lnd macaroon no longer grants broad offchain write access.
    It only allows reads and the UpdateChannelPolicy and UpdateChanStatus RPCs.
    Other applications that reused this macaroon need their own macaroon with
    the appropriate permissions. lnd regenerates /run/lnd/charge-lnd.macaroon
    when it restarts during deployment.
  '';
}
