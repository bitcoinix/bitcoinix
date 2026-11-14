{ options, ... }:

{
  condition = options.services.lnd.lndconnectOnion.isDefined;
  message = ''
    The `lndconnect-rest-onion` binary has been renamed to `lndconnect`.
  '';
}
