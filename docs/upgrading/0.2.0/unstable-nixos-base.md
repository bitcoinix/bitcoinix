#### Unstable NixOS base

bitcoinix now bases its systems and packages on unstable nixpkgs only. The single
`nixpkgs` input tracks `nixos-unstable`; remove any follows declarations targeting
`bitcoinix/nixpkgs-unstable`. Continue following `bitcoinix/nixpkgs` for your node.
The system itself must be evaluated with unstable nixpkgs, regardless of
`nix-bitcoin.useVersionLockedPkgs`. NixOS 26.05 evaluation fails before migration
assertions run, even without I2P or namespace isolation, with an error such as
``The option `services.i2pd.checkConfig' does not exist``.
Switch your system's nixpkgs input to unstable before evaluating this release.
If your system follows `bitcoinix/nixpkgs`, as the deployment examples do, updating
bitcoinix moves the whole OS from NixOS 26.05 to unstable, not only service packages.
