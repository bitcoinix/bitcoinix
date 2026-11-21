{ ... }:

{
  condition = true;
  message = ''
    bitcoinix now uses only unstable nixpkgs via the `nixpkgs` flake input.
    Remove follows declarations for the removed `nixpkgs-unstable` input.
    In the flake NixOS module, `nix-bitcoin.useVersionLockedPkgs` now defaults
    to true. Packages use bitcoinix's tested revision unless you override its
    nixpkgs input, for example with `bitcoinix.inputs.nixpkgs.follows`.
    Your system's nixpkgs.overlays and nixpkgs.config do not apply to these
    packages. Setting the option to false retains system customizations of
    the packages that the service packages depend on. The service packages
    themselves keep the versions of bitcoinix's pkgs/, and overlays on them
    don't apply. Non-flake module imports also use the system pin and do not
    provide this option. With a system pin newer than bitcoinix's, compare the
    daemon versions before deploying: an older lnd or clightning may refuse a
    database written by a newer version.
    The system itself must use unstable nixpkgs regardless of this option.
    Systems following bitcoinix/nixpkgs move the whole OS to unstable.
    NixOS 26.05 fails before this notice with an error such as
    "The option `services.i2pd.checkConfig' does not exist".
    Custom calls to `lib.mkNbPkgs` or `pkgs/default.nix` must drop
    `pkgsUnstable`; `pinned` now contains only `pkgs` and the package entries.
  '';
}
