#### netns-isolation forwards only namespace traffic

netns-isolation turns on IPv4 forwarding for the NAT of the service namespaces. Before,
it added no forwarding rules, so the host forwarded traffic between all its interfaces.
On a node with two networks, for example a LAN and a VPN, a host on one side could reach
the other side through the node.

Now the unit `nb-netns-forward` adds the iptables chain `nb-netns-forward` and appends a
jump to it to the `FORWARD` chain. The chain accepts the connections that a namespace
opens and their replies, and drops all other forwarded IPv4 traffic.

Evaluation fails when `boot.kernel.sysctl."net.ipv4.conf.all.forwarding"` is on.
`networking.nat`, Docker and Tailscale with `useRoutingFeatures` set to `server` or
`both` turn it on. Other tools can route through the node without this setting, for
example libvirt, Podman, Incus or systemd-networkd with `IPMasquerade`. Their forwarded
traffic is now dropped too, unless their own rules accept it before the jump. If this
node routes for other networks, set this.

```nix
nix-bitcoin.netns-isolation.restrictForwarding = false;
```

netns-isolation then adds no forwarding rules, and the host forwards between all its
interfaces like before, unless you filter forwarded traffic yourself.

To keep the rules and allow some forwarded traffic, insert your `ACCEPT` rules at the
top of `FORWARD`. A rule that's appended after the jump has no effect. An `accept` in an
nftables table of its own doesn't help either, because the packet still passes the
`FORWARD` chain of iptables. For example, this lets hosts on `wg0` reach the LAN on
`eth0`. The firewall runs the stop commands before the start commands on each reload,
also before the rule exists, so the delete must not fail.

```nix
networking.firewall.extraCommands = ''
  iptables -w -I FORWARD -i wg0 -o eth0 -j ACCEPT
  iptables -w -I FORWARD -i eth0 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
'';
networking.firewall.extraStopCommands = ''
  iptables -w -D FORWARD -i wg0 -o eth0 -j ACCEPT 2>/dev/null || true
  iptables -w -D FORWARD -i eth0 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
'';
```

To list the rules and count the dropped packets, run this as root.

```shell
iptables -vnL nb-netns-forward
```
