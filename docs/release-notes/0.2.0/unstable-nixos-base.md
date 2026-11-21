#### Unstable NixOS base

bitcoinix now uses a single `nixpkgs` input tracking `nixos-unstable` for its system
and packages. `nix-bitcoin.useVersionLockedPkgs` defaults to `true`. Review the
[0.2.0 migration guide](../../upgrading/0.2.0.md) for the system
input, package customization, reverse-path filtering, FUSE, I2P validation and
systemd-nspawn changes. Non-flake module imports, disabling version-locked
packages, or overriding bitcoinix's nixpkgs input now build the service packages
with the caller's nixpkgs.
