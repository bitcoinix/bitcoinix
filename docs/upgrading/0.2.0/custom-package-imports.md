#### Custom package imports

Custom calls to `lib.mkNbPkgs` or `pkgs/default.nix` must remove `pkgsUnstable`.
Use `pinned.pkgs` in place of `pinned.pkgsUnstable`. The deployment shell no longer
exports `nixpkgsUnstable`; use the `nixpkgs` entry in `NIX_PATH` instead.
The dependency update helper no longer accepts a NixOS release argument.
