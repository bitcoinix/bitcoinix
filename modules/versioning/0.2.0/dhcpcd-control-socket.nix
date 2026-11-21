{ config, lib, pkgs, ... }:

{
  # The security fixes in pkgs/security-fixes.nix update dhcpcd to 10.5.2
  condition = config.nix-bitcoin.securityFixes.enable && config.systemd.services ? dhcpcd
    && lib.versionAtLeast pkgs.dhcpcd.version "10.5";
  message = ''
    The node now runs dhcpcd 10.5 or later. Only root and dhcpcd's own user can use
    dhcpcd's control socket, so commands like `dhcpcd -U` and `dhcpcd --dumplease`
    fail for other users. Run them as root.
  '';
}
