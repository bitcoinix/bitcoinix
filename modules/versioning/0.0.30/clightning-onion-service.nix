{ config, ... }:

{
  condition = config.services.clightning.enable;
  message = ''
    The onion service for clightning has been disabled in the default
    configuration (`secure-node.nix`).

    To enable the onion service, add the following to your configuration:
    nix-bitcon.onionServices.clightning.enable = true;
  '';
}
