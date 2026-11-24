#### netns-isolation rejects an nftables ruleset flush

With `networking.nftables` and iptables-nft, netns-isolation now fails evaluation when
`networking.nftables.flushRuleset` is on, or when `networking.nftables.tables` has a table
that iptables-nft uses, like `ip nat`, `ip filter` or `ip mangle`. The flush deleted the
NAT rule of the namespace bridge, the forwarding rules of `nb-netns-forward` and the host
firewall, and such a table replaced the iptables table of the same name. Without the NAT
rule, the namespaces couldn't reach anything beyond the host. Without the forwarding rules,
the host forwarded traffic between all its interfaces. Without the mangle tables, the host
firewall didn't check the reverse path. NixOS turns the flush on by default when
`networking.nftables.ruleset` or `rulesetFile` is set or `system.stateVersion` is older
than 23.11. A firewall that runs `pkgs.iptables-legacy` as `networking.firewall.package` is
exempt. The first deploy after such a fix still runs the old deletions once. See
[Upgrading to config version 0.2.1](../../upgrading/0.2.1/netns-isolation-rejects-an-nftables-ruleset-flush.md).

`nb-netns-bridge` now also stops and starts again when its NAT rule is gone. Before, the
stop failed and left the bridge behind, so the next start failed too. Now a start deletes
such a bridge, which still has its address. When another link has the name `nb-br`, the
start fails and leaves that link alone.
