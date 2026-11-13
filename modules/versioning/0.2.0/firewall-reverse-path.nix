{ config, ... }:

{
  condition = config.networking.firewall.enable
    && config.networking.firewall.checkReversePath == "loose";
  message = ''
    Unstable NixOS changes networking.firewall.checkReversePath from true
    (strict) to "loose", accepting sources reachable through any interface.
    To retain strict checking, set networking.firewall.checkReversePath = true;
    after reviewing your routing and VPN requirements.
  '';
}
