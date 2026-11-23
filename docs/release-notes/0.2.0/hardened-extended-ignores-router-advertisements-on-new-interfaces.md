#### hardened-extended ignores router advertisements on new interfaces

The `hardened-extended.nix` preset set `net.ipv6.default.accept_ra`, which doesn't
exist, so it had no effect. It now sets `net.ipv6.conf.default.accept_ra = 0`, so the
kernel ignores IPv6 router advertisements on interfaces that appear after the sysctl
settings are applied at boot. Interfaces on which dhcpcd or systemd-networkd handle
router advertisements are unaffected. Others, for example a VLAN with `useDHCP = false`
or any interface with `networking.dhcpcd.IPv6rs = false`, no longer get an IPv6
address or default route from router advertisements. A migration notice lists the
options, see the
[upgrade notes](../../upgrading/0.2.0/hardened-extended-ignores-router-advertisements-on-new-interfaces.md).
