{ config, ... }:

let
  cfg = config.bitcoinix.netns-isolation;
in
{
  # The old config is unknown, and turning `networking.nftables` off also runs
  # its saved deletions on stop, so this shows whenever netns-isolation or the
  # host firewall uses iptables-nft.
  condition = cfg.enable && cfg.usesNftables;
  message = ''
    With netns-isolation and iptables-nft (the default `pkgs.iptables`),
    evaluation now fails while `networking.nftables` is on with
    `networking.nftables.flushRuleset` or with a table in
    `networking.nftables.tables` that iptables-nft uses. If the config that
    runs now has such a flush or table, `nftables.service` still runs the old deletions once
    when you fix the config or turn `networking.nftables` off, deleting the
    rules in the affected tables (the bridge NAT rule, the forwarding rules or
    the host firewall). Reboot once after that deploy, or restore the rules
    with the steps in the upgrade notes. If the config that runs now did not
    enable `networking.nftables`, no action is needed.
  '';
}
