#### Service package selection

With the flake's NixOS module, `nix-bitcoin.useVersionLockedPkgs` now defaults to
`true`, including for local package builds. Your system's `nixpkgs.overlays` and
`nixpkgs.config` no longer apply to the pinned service packages, including bitcoind,
lnd and clightning.
Review any security patches or other customizations supplied through overlays:
set `nix-bitcoin.useVersionLockedPkgs = false` to use your system's customized
unstable package set, or explicitly override the affected service's package.
Overlays on the packages that bitcoinix copies into `pkgs/by-name`, like nbxplorer,
don't reach them with either setting, so set the service's `package` option for those.

The formerly separate unstable service packages (including lnd and clightning)
now also follow your system's nixpkgs when you set this option to `false` or
import the NixOS modules without flakes. Non-flake module imports do not provide
the `useVersionLockedPkgs` option. If your flake sets
`bitcoinix.inputs.nixpkgs.follows = "nixpkgs"`, even the option's default `true`
uses your chosen input instead of bitcoinix's tested revision. This is different
from having your system's `nixpkgs.follows = "bitcoinix/nixpkgs"`, which keeps the
bitcoinix pin.

In these setups, pin your own nixpkgs and review service versions before each
update against the [tested versions](../../introduction.md#software-versions). An update can upgrade
or downgrade a daemon independently of bitcoinix; an older lnd or clightning may
refuse a database written by a newer version. Follow the daemon's migration
instructions and do not assume rolling back nixpkgs can roll back its database.

Keep your existing `system.stateVersion`: it controls state compatibility and does
not select the nixpkgs channel.
