#### Service package selection

With the flake's NixOS module, `nix-bitcoin.useVersionLockedPkgs` now defaults to
`true`, including for local package builds. Your system's `nixpkgs.overlays` and
`nixpkgs.config` no longer apply to the pinned service packages, including bitcoind,
lnd and clightning.
Review any security patches or other customizations supplied through overlays:
set `nix-bitcoin.useVersionLockedPkgs = false` to use your system's customized
unstable package set, or explicitly override the affected service's package.
Overlays on the packages that bitcoinix copies into `pkgs/by-name`, which are the
Bitcoin and Lightning packages, don't reach them with either setting. Set the service's
`package` option instead, like `services.lnd.package`, where the service has one.

The service packages, including lnd and clightning, come from bitcoinix's `pkgs/`.
When you set this option to `false` or import the NixOS modules without flakes, they
keep their versions and build with your system's nixpkgs. Non-flake module imports do not provide
the `useVersionLockedPkgs` option. If your flake sets
`bitcoinix.inputs.nixpkgs.follows = "nixpkgs"`, even the option's default `true`
uses your chosen input instead of bitcoinix's tested revision. This is different
from having your system's `nixpkgs.follows = "bitcoinix/nixpkgs"`, which keeps the
bitcoinix pin.

In these setups, pin your own nixpkgs and review its updates. It supplies the
libraries and build tools of the service packages, and the
[tested versions](../../introduction.md#software-versions) are those of bitcoinix's pin.
If your node runs a daemon that is newer than the version in the table, for example
because it followed master with a newer nixpkgs, this update moves it back. Compare the
versions before you deploy: an older lnd or clightning may refuse a database written
by a newer version.

Keep your existing `system.stateVersion`: it controls state compatibility and does
not select the nixpkgs channel.
