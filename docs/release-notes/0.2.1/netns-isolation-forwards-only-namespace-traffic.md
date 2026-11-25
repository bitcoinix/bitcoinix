#### netns-isolation forwards only namespace traffic

With netns-isolation, the host forwarded traffic between all its interfaces. So on a
node with a LAN and a VPN, or with two LANs, a host on one side could reach the other
side through the node. Now the host forwards only the connections that the service
namespaces open and their replies, and drops all other forwarded IPv4 traffic. The new
option `nix-bitcoin.netns-isolation.restrictForwarding` turns this off. Evaluation fails
while `networking.nat`, Docker or another module turns on
`net.ipv4.conf.all.forwarding`, until you set the option to `false`. See
[Upgrading to config version 0.2.1](../../upgrading/0.2.1/netns-isolation-forwards-only-namespace-traffic.md).
