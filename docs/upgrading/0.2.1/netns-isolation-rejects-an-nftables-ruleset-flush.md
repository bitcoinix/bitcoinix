#### netns-isolation rejects an nftables ruleset flush

With `networking.nftables` and iptables-nft, the NAT rule of the namespace bridge, the
forwarding rules of `nb-netns-forward` and the host firewall live in the nftables ruleset.
netns-isolation now fails evaluation when `networking.nftables.flushRuleset` is on. With
the flush, each start, reload or stop of `nftables.service` deletes these rules. NixOS
turns the flush on by default when `networking.nftables.ruleset` or `rulesetFile` is set
or `system.stateVersion` is older than 23.11.

Evaluation also fails when `networking.nftables.tables` has a table that iptables-nft
uses. `nftables.service` deletes and creates such a table again on each start or reload, and deletes it on stop,
so it replaces the iptables table of the same name. These tables count.

- `ip nat` holds the NAT rule of the bridge.
- `ip filter` holds the host firewall and the forwarding rules. It counts while
  `networking.firewall.enable` or `nix-bitcoin.netns-isolation.restrictForwarding` is on.
- `ip6 filter` holds the host firewall for IPv6. It counts with
  `networking.firewall.enable` and `networking.enableIPv6`.
- `ip mangle` and `ip6 mangle` hold the reverse path check of the host firewall. They
  count with `networking.firewall.enable` while `networking.firewall.checkReversePath`
  isn't `false`. The default is `"loose"`. `ip6 mangle` counts only with
  `networking.enableIPv6`.

A firewall that runs `pkgs.iptables-legacy` as `networking.firewall.package` is exempt,
since its rules live outside the nftables ruleset.

Put your nftables rules in `networking.nftables.tables` and turn the flush off. Rename
such a table or use the `inet` family.

```nix
networking.nftables.flushRuleset = false;
networking.nftables.tables.my-rules = {
  family = "inet";
  content = ''
    # Your chains and rules
  '';
};
```

`nftables.service` keeps the deletions of the config it loaded last and runs them on its
next reload or stop. So the first deploy after such a fix still runs the old flush or
deletes the old table once. This also happens when you fix the config in the same deploy
as this update, so that evaluation doesn't fail, and when you turn off
`networking.nftables`. Reboot once after that deploy. Or run these commands as root in
this order.

```shell
systemctl reload-or-restart firewall.service
systemctl reload-or-restart nb-netns-forward.service
systemctl restart nb-netns-bridge.service
```

Skip the first command without `networking.firewall.enable` and the second without
`nix-bitcoin.netns-isolation.restrictForwarding`. A reload adds the rules again in place.
A restart of `firewall.service` or `nb-netns-forward.service` removes the rules that are
still there before it adds them again, so the host accepts or forwards all traffic for a
moment. The restart of `nb-netns-bridge.service` also restarts every service in a
namespace.
