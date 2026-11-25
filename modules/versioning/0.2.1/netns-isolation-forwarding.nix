{ config, ... }:

let
  cfg = config.nix-bitcoin.netns-isolation;
in
{
  condition = cfg.enable && cfg.restrictForwarding;
  message = ''
    With netns-isolation, the host now forwards only the traffic of the
    service namespaces and drops all other forwarded IPv4 traffic. If this
    node routes for other networks, for example for VMs, containers, a VPN or
    a second LAN, set `nix-bitcoin.netns-isolation.restrictForwarding = false;`.
  '';
}
