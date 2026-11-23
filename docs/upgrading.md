# Upgrading

Some releases contain changes that need manual action, such as a removed service, a
changed default or a required reindex. bitcoinix reports them when it evaluates your
configuration: if a released change is newer than `nix-bitcoin.configVersion` and
affects your configuration, evaluation fails with a short description of the change.
Options of removed services and other service assertions can fail evaluation
regardless of the config version.

Keep `nix-bitcoin.configVersion` set to the released version whose migrations you
have completed. Values newer than the latest finalized release in `version.nix`
are rejected; use the released version named in the error until release finalization.
If the option is unset, migration errors and warnings are disabled.
Keep this value explicit: importing the project's `version.nix` would automatically
acknowledge migrations on each release.

When evaluation fails after an update, follow the version pages below for each version
newer than your config version, starting with the oldest. Then set
`nix-bitcoin.configVersion` to the version named in the error message.

On `master`, review unreleased migration warnings before deploying and keep
`configVersion` at the latest release. These warnings do not block deployment or
require acknowledgement: deployment can proceed even before a required migration
is completed. They cannot be acknowledged individually and can repeat after
migration while their conditions still apply. Once the release is finalized, its
notices become errors until you acknowledge them by updating `configVersion` after migrating.

## Updating bitcoinix
Review the [release notes](./release-notes.md) for changes to packages and flake attributes.

With a [flake-based deployment](./install.md#4-deploy-with-a-flake), verify the new release tag as in
step 3 of the installation, set it in `flake.nix`, run `nix flake lock` and check the locked commit
as in step 4.2. Then deploy.

With krops, run `update-nix-bitcoin` from the [deployment shell](./configuration.md#deployment-shell).\
This fetches the latest release, verifies the signature on its release tag and updates `nix-bitcoin-release.nix`.\
It refuses to switch to a release older than the one currently pinned. To downgrade on purpose,
run `fetch-release.sh` with `releaseVersion=<version>` and write its output to `nix-bitcoin-release.nix`.

During development, each change has its own file under `docs/upgrading/<version>/`.
At release time, the draft files are combined into `docs/upgrading/<version>.md`.
See [Cutting a release](https://github.com/bitcoinix/bitcoinix/blob/master/dev/README.md#cutting-a-release).

## Versions

- [0.2.0](upgrading/0.2.0.md)
- <a id="upgrading-to-config-version-016"></a>[0.1.6](upgrading/0.1.6.md)
- <a id="upgrading-to-config-version-015"></a>[0.1.5](upgrading/0.1.5.md)
- <a id="upgrading-to-config-version-013"></a>[0.1.3](upgrading/0.1.3.md)
- <a id="upgrading-to-config-version-012"></a>[0.1.2](upgrading/0.1.2.md)
- <a id="upgrading-to-config-version-011"></a>[0.1.1](upgrading/0.1.1.md)
- <a id="upgrading-to-config-version-010"></a>[0.1.0](upgrading/0.1.0.md)
