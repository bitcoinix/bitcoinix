{ config, ... }:

let
  sysctl = "net.ipv6.conf.default.accept_ra";
in
{
  # dhcpcd and systemd-networkd handle router advertisements only on the
  # interfaces they manage, and NixOS excludes interfaces in many ways, so
  # report every config that imports the preset and keeps its setting.
  # The preset declares a marker option: with `imports = [ (import <preset>) ]`,
  # its definitions are attributed to the importing file.
  condition = config.nix-bitcoin ? hardened-extended-preset-enabled
    && toString (config.boot.kernel.sysctl.${sysctl} or "") == "0"
    && !config.boot.isContainer
    && config.networking.enableIPv6;
  message = ''
    The hardened-extended preset set `net.ipv6.default.accept_ra`, which doesn't
    exist, so it had no effect. It now sets `net.ipv6.conf.default.accept_ra = 0`,
    so the kernel ignores IPv6 router advertisements on each interface that
    appears after the sysctl settings are applied at boot. This can include your
    main network interface or a VLAN. dhcpcd and systemd-networkd handle router
    advertisements themselves, but only on the interfaces they manage.
    If another interface gets its IPv6 address or default route from router
    advertisements, configure it statically or let dhcpcd or systemd-networkd
    manage it (`networking.interfaces.<name>.useDHCP = true;`) before deploying.
    To keep the previous behavior, set
    `boot.kernel.sysctl."net.ipv6.conf.default.accept_ra" = lib.mkForce "1";`.
  '';
}
