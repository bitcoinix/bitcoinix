#### dhcpcd control socket

Nodes that use dhcpcd now run dhcpcd 10.5.2 from
[bitcoinix's security fixes](../../configuration.md#security-fixes-for-nixpkgs-packages).
Since 10.5, only root and dhcpcd's own user can use its control socket, so commands
like `dhcpcd -U` and `dhcpcd --dumplease` fail for other users. Run them as root.

To keep the dhcpcd of your nixpkgs, set `nix-bitcoin.securityFixes.enable = false`.
That turns off the other security fixes too.
