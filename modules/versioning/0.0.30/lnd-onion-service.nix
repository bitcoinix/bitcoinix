{ config, ... }:

{
  condition = config.services.lnd.enable;
  message = ''
    The onion service for lnd has been disabled in the default
    configuration (`secure-node.nix`).

    To enable the onion service, add the following to your configuration:
    nix-bitcon.onionServices.lnd.enable = true;
  '';
}
