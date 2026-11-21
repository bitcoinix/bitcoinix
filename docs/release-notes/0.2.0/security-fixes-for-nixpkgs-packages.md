#### Security fixes for nixpkgs packages

bitcoinix now ships urgent security fixes for nixpkgs packages before they reach
nixpkgs. Each fix turns itself off once nixpkgs has the fixed version. The first one
updates dhcpcd, the default DHCP client of NixOS, to 10.5.2, which fixes
CVE-2026-56113, CVE-2026-56114, CVE-2026-56116 and CVE-2026-56117. See
[security fixes for nixpkgs packages](../../configuration.md#security-fixes-for-nixpkgs-packages)
and [Upgrading to config version 0.2.0](../../upgrading/0.2.0/dhcpcd-control-socket.md).
