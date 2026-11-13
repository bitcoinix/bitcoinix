# Release notes

For configuration migrations reported during evaluation, follow the
[upgrading guide](upgrading.md).

## 0.2.0

bitcoinix now uses a single `nixpkgs` input tracking `nixos-unstable` for its system
and packages. `nix-bitcoin.useVersionLockedPkgs` defaults to `true`. Review the
[0.2.0 migration guide](upgrading.md#upgrading-to-config-version-020) for the system
input, package customization, reverse-path filtering, FUSE, I2P validation and
systemd-nspawn changes. Non-flake module imports, disabling version-locked
packages, or overriding bitcoinix's nixpkgs input now also move the formerly
separately pinned unstable service packages with the caller's nixpkgs.

The pinned TrustedCoin package carries a local initialization patch until a release
includes the [upstream startup fix](https://github.com/nbd-wtf/trustedcoin/pull/44).
The pinned electrs package supplies the missing pkg-config and zstd build inputs.

The generated `pkgs/pinned.nix` file has been removed. Package selection and
local overrides now live together in `pkgs/default.nix`; the public
`legacyPackages.<system>.pinned` paths remain available. The deployment shell and
package imports without an explicit `pkgs` still read the lock file through
`pkgs/nixpkgs-pinned.nix`; non-flake NixOS module imports use the system's `pkgs`.

## 0.1.6

RTL now uses the nixpkgs package. Replace explicit flake references to
`packages.<system>.rtl` or `legacyPackages.<system>.rtl` with
`legacyPackages.<system>.pinned.rtl`. For example, build it with
`nix build '.#legacyPackages.aarch64-linux.pinned.rtl'` (or `x86_64-linux`).
The service still uses `nix-bitcoin.pkgs.rtl` automatically.

TrustedCoin now uses the nixpkgs package. Replace explicit flake references to
`packages.<system>.trustedcoin` or `legacyPackages.<system>.trustedcoin` with
`legacyPackages.<system>.pinned.trustedcoin`. For example, build it with
`nix build '.#legacyPackages.aarch64-linux.pinned.trustedcoin'` (or `x86_64-linux`).
The plugin still uses `nix-bitcoin.pkgs.trustedcoin` automatically.

Trezor now uses the unmodified nixpkgs-unstable package. Replace explicit package
references to `nix-bitcoin.pkgs.pyPkgs.nbPython3PackagesWithUnlockedEcdsa.trezor`
with `nix-bitcoin.pkgs.nbPython3Packages.trezor`. The
`services.hardware-wallets.trezor` option selects it automatically; `trezorctl`
remains available. HWI retains its separate ECDSA exception.

`nbPython3Packages` now uses nixpkgs-unstable's Python interpreter and package set,
including `pyln-bolt7`, `pyln-client`, `pyln-proto` and `pylightning`. Their versions
are selected by nixpkgs-unstable independently of the Core Lightning daemon.
In custom configurations, build Python environments with the matching interpreter,
for example:

```nix
config.nix-bitcoin.pkgs.nbPython3Packages.python.withPackages (ps: [ ps.pyln-client ])
```

The built-in Python plugins select this interpreter automatically. The package
paths under `nbPython3Packages` remain available.

## 0.1.5

The clnrest package has moved from `nix-bitcoin.pkgs.clnrest` to
`nix-bitcoin.pkgs.clightning-plugins.clnrest`. Update explicit package references
in custom configurations and scripts. For flake builds, use
`'.#packages.aarch64-linux.clightning-plugins/clnrest'` (or `x86_64-linux`)
instead of `'.#packages.aarch64-linux.clnrest'`.
The default package is selected automatically, including when RTL enables clnrest.
If you have no custom package references, this rename requires no manual changes.

For this release's configuration and service migrations, see
[Upgrading to config version 0.1.5](upgrading.md#upgrading-to-config-version-015).
