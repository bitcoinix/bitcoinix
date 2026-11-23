#### hardened-extended ignores router advertisements on new interfaces

The `hardened-extended.nix` preset now sets `net.ipv6.conf.default.accept_ra = 0`
instead of a sysctl that doesn't exist. The kernel then ignores IPv6 router
advertisements on interfaces that appear after the sysctl settings are applied at
boot, which can include your main network interface. dhcpcd and systemd-networkd
handle router advertisements themselves, but only on the interfaces they manage.
They skip, for example, interfaces with `useDHCP = false` or a static IPv4 address,
all interfaces with `networking.dhcpcd.IPv6rs = false`, and
with systemd-networkd, VLANs, bridges and bonds, because its default networks match
only physical interfaces. Evaluation reports this for each config with the preset
and IPv6.

If an interface gets its IPv6 address or default route from router advertisements,
before deploying, do one of these:

- Configure the address and route statically, for example with
  `networking.interfaces.<name>.ipv6.addresses` and `networking.defaultGateway6`.
- Let dhcpcd or systemd-networkd manage the interface:
  `networking.interfaces.<name>.useDHCP = true;`.
- With a static IPv6 address, let dhcpcd solicit router advertisements:
  `networking.dhcpcd.IPv6rs = true;`.
- Keep the previous behavior:
  `boot.kernel.sysctl."net.ipv6.conf.default.accept_ra" = lib.mkForce "1";`.
