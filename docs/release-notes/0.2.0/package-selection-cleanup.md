#### Package selection cleanup

The generated `pkgs/pinned.nix` file has been removed. Package selection and
local overrides now live together in `pkgs/default.nix`; the public
`legacyPackages.<system>.pinned` paths remain available. The deployment shell and
package imports without an explicit `pkgs` still read the lock file through
`pkgs/nixpkgs-pinned.nix`; non-flake NixOS module imports use the system's `pkgs`.
