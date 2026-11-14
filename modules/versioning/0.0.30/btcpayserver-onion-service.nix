{ config, ... }:

{
  condition = config.services.btcpayserver.enable;
  message = ''
    The onion service for btcpayserver has been disabled in the default
    configuration (`secure-node.nix`).

    To enable the onion service, add the following to your configuration:
    nix-bitcon.onionServices.btcpayserver.enable = true;
  '';
}
