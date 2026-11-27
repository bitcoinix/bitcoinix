# Migrate from nix-bitcoin

bitcoinix continues [nix-bitcoin](https://github.com/fort-nix/nix-bitcoin), which was archived
in August 2026 after its last release, v0.0.139. A nix-bitcoin node switches to bitcoinix in
place: the NixOS options keep the `nix-bitcoin.*` prefix and the services keep their data
and secrets. What changes is where you get releases,
the NixOS base, and the services that bitcoinix no longer supports.

## Before you start

- **Your system moves to NixOS unstable.** nix-bitcoin offered a stable NixOS base;
  bitcoinix uses only `nixos-unstable`. When your system follows bitcoinix's `nixpkgs`, as
  the deployment examples do, the switch updates the whole OS, not only the Bitcoin
  services. Read the [0.2.0 upgrade notes](upgrading/0.2.0.md) first.
- **Some services were removed.** The options of joinmarket, liquidd, lightning-loop,
  lightning-pool, spark-wallet and clightning-rest, among others, now fail evaluation with
  the reason and what to do instead. The data of removed services stays on the node.
  The full list is in
  [`modules/obsolete-options.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/modules/obsolete-options.nix).
- **Releases are signed differently.** bitcoinix releases are git tags signed with SSH
  keys, which you verify yourself. Don't follow a branch, as with nix-bitcoin's `release`
  branch: pin a verified tag.
- Back up your node, above all the [secrets dir](configuration.md#secrets-dir) set by
  `nix-bitcoin.secretsDir` and your Lightning [backups](service/backups.md). The secrets
  dir defaults to `/var/src/secrets` with krops and to `/etc/nix-bitcoin-secrets`
  otherwise. With krops, also back up the `secrets/` directory in your deployment
  directory, from which krops copies the secrets to the node.

## 1. Get and verify bitcoinix

In the directory that contains your deployment directory, follow
[step 3 of the installation](install.md#3-get-and-verify-bitcoinix): clone bitcoinix,
verify the release signing key and check out the latest release tag. The steps below and
step 4.2 of the installation expect the clone at `../bitcoinix`, next to your deployment
directory.

## 2. Switch your deployment to bitcoinix

### Flake

In your node's `flake.nix`, replace the nix-bitcoin input and the inputs that follow it:

```nix
inputs = {
  bitcoinix.url = "github:bitcoinix/bitcoinix/v<version>";
  nixpkgs.follows = "bitcoinix/nixpkgs";
};
```

Remove `nixpkgs-unstable.follows = "nix-bitcoin/nixpkgs-unstable"`: bitcoinix has no
separate unstable input. In `outputs`, rename the `nix-bitcoin` argument and its uses, e.g.
`bitcoinix.nixosModules.default` and `(bitcoinix + "/modules/presets/secure-node.nix")`.
The module and the presets keep these paths, but some package outputs moved: for example,
`packages.<system>.rtl` is now `legacyPackages.<system>.pinned.rtl`. If your flake refers
to packages of the nix-bitcoin flake, look up their new names in the
[release notes](release-notes.md). Compare your flake with
[`examples/flakes/flake.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/examples/flakes/flake.nix).

If your node is a container based on nix-bitcoin's container example, start from bitcoinix's
[`examples/container/flake.nix`](https://github.com/bitcoinix/bitcoinix/blob/master/examples/container/flake.nix)
instead and take over your container configuration. The rename above drops the
`extra-container` input, and bitcoinix has no `test/lib/extra-container-workaround.nix`.

Then lock the inputs and check the locked commit, as in
[step 4.2 of the installation](install.md#4-deploy-with-a-flake).

### krops

If the [deployment shell](configuration.md#deployment-shell) is open, exit it: it keeps
using nix-bitcoin until you start it again. In your deployment directory, replace
`nix-bitcoin-release.nix` with the release that you verified in step 1, e.g. `0.2.0`:

```
releaseVersion=<version> ../bitcoinix/helper/fetch-release.sh > nix-bitcoin-release.nix.new &&
  mv nix-bitcoin-release.nix.new nix-bitcoin-release.nix
```

This replaces the pin only when the release was fetched and verified. Then start the
deployment shell again with `nix-shell`; its `update-nix-bitcoin` now updates from
bitcoinix releases. Compare your `krops/` directory with bitcoinix's
[`examples/krops`](https://github.com/bitcoinix/bitcoinix/tree/master/examples/krops) and take
over its changes. krops is a legacy deployment method in bitcoinix; consider
[moving to a flake](install.md#4-deploy-with-a-flake).

## 3. Migrate your configuration

1. Keep `nix-bitcoin.configVersion` at the nix-bitcoin version that your configuration is
   written for, e.g. `"0.0.85"`, and evaluate your configuration (for example, build it
   without deploying). Evaluation fails and lists each change since that version that
   affects your configuration.
2. Complete these changes, following the [upgrade notes](upgrading.md) of each version
   from 0.1.0 on, oldest first. Several need action on the node, such as deleting the
   electrs index before deploying (0.1.3). The error stays after you complete them: the
   notices check your configuration, e.g. whether a service is enabled, not the node.
3. Set `bitcoinix.configVersion` to the version named in the error, the bitcoinix
   release you are deploying. Rename your other `nix-bitcoin.*` options to `bitcoinix.*`;
   the old prefix still works, but evaluation warns about it.
4. Evaluate again. Deploy only when evaluation succeeds.

If `configVersion` is unset, evaluation doesn't report these changes. Set it to your
nix-bitcoin version before you switch, so that you don't miss a required migration.

## 4. Deploy

Deploy as described for [flakes](install.md#4-deploy-with-a-flake) or
[krops](install.md#deploy-with-krops). Because the OS itself changes, activate the new
system at boot and reboot instead of using `switch`:

- With a flake, use `boot` as described in step 4.4 of the installation.
- With krops, `deploy` always switches. Add `operation = "boot";` to the `writeDeploy`
  arguments in `krops/deploy.nix`, deploy, then reboot the node with
  `ssh bitcoin-node reboot`.

Afterwards, check the services, e.g. with `nodeinfo` and `systemctl --failed`.

If something doesn't work, please [open an issue](https://github.com/bitcoinix/bitcoinix/issues).
