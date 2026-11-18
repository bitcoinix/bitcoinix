> [!NOTE]
> This documentation may be outdated. It is being updated.

This directory contains docs and helper scripts for developing and debugging:

- [`dev.sh`](./dev.sh): misc dev helpers
- [`dev-features.sh`](./dev-features.sh): helpers for developing specific
  bitcoinix features, like services
- [`topics`](./topics) features specific topics
- [`dev-scenarios.nix`](./dev-scenarios.nix): extra test scenarios used in the above scripts

See also: [test/README.md](../test/README.md)

## Developing on macOS

The supported build targets are `x86_64-linux` and `aarch64-linux`. On a Mac,
run the development commands in Linux using
[the macOS build guide](./macos.md): prefer OrbStack when `orb` is installed,
with Docker as a fallback. The guide covers setup, sharing the current checkout,
package builds, and checks that do not need a VM. Nix on macOS is optional.

## Pull request labels

The [labeler workflow](../.github/workflows/labeler.yml) automatically adds area labels
when pull requests are opened, updated or reopened. A single `github-script` step
applies the path rules defined in the workflow and adds `type: feature` for added
definition files and `type: removal` for deleted ones (`modules/**/*.nix` and
`pkgs/**/*.nix`). Both type labels can apply to the same PR. Edits to existing
files and file renames do not trigger these type labels. Area and type labels are
only added, so previously applied labels remain.

The workflow also adds `status: rebase needed` to open PRs with merge conflicts
against their current target branch, and removes it when they merge cleanly.
It checks all open PRs on PR creation, updates, reopening and edits (including
target branch changes), on pushes to any branch, and hourly. It can also be run
manually from the Actions tab. Unknown mergeability results are retried; if GitHub
has not finished calculating, the label stays unchanged until a later run.
Failing checks, missing reviews and being behind the target branch do not by
themselves cause this label. The workflow uses only the GitHub API and never
checks out PR code. Other type, status and breaking labels are applied manually.

To edit area labels, change the `areaRules` lists near the top of the workflow.
Each label can have `directories` (recursive, with a trailing `/`), `files` (exact
paths from the repository root), `names` (filenames at any depth, such as
`README.md`), and `patterns` (globs such as `helper/update-flake.*`). Matching any
entry applies the label; multiple area labels can apply to the same file.
For example, add `'helper/'` to a label's `directories` list to include all helper
scripts, or add `'helper/make-release.sh'` to its `files` list to include just that
script. Keep label names aligned with the
[repository labels](https://github.com/bitcoinix/bitcoinix/labels).
Use `directories` and `names` for recursive matching that includes hidden files;
`patterns` uses Node's `path.matchesGlob`, whose wildcards skip hidden names.

## Run a dev shell

Run these commands inside the Linux environment selected above when using a Mac.

There are two ways to run a dev shell:

### 1. Run command `nix develop`

This starts a shell with [`test/run-tests.sh`](../test/run-tests.sh) and
the scripts in dir [`helper`](../helper) added to `PATH`.

<a id="2-setup-and-start-the-direnv-dev-env"></a>

### 2. Set up and start the `direnv` dev env

This is an opinionated, [direnv](https://direnv.net/)-based dev env, optimized for developer experience.

[`dev-env/create.sh`](./dev-env/create.sh) creates a git repo with the following contents:
- Dir `src` which contains the bitcoinix repo
- Dir `bin` for helper scripts
- File `scenarios.nix` for custom test scenarios
- File `.envrc` that defines a [direnv](https://direnv.net/) environment,
  mainly for adding bitcoinix and helper scripts to `PATH`

#### Installation

1. [Install direnv](https://direnv.net/docs/installation.html).\
   If you use NixOS (and Bash as the default shell), just add the following to your system config:
   ```nix
     environment.systemPackages = [ pkgs.direnv ];
     programs.bash.interactiveShellInit = ''
       eval "$(direnv hook bash)"
     '';
   ```

2. Create the dev env:
   ```bash
   # Set up a dev environment in dir ~/dev/nix-bitcoin.
   # The dir is created automatically.
   ./dev-env/create.sh ~/dev/nix-bitcoin

   cd ~/dev/nix-bitcoin

   # Enable direnv
   direnv allow
   ```

3. Optional: Editor integration
   - Add envrc support to your editor
   - Set up your editor so you can easily execute lines or paragraphs from a shell script
     file in a shell.\
     This simplifies using dev helper scripts like [`./dev.sh`](./dev.sh).

#### Explore the dev env
```bash
# The direnv is automatically activated when visiting any subdir of ~/dev/nix-bitcoin
cd ~/dev/nix-bitcoin

ls -al . bin lib

# The direnv config file
cat .envrc

# You can use this file to define extra scenarios
cat scenarios.nix

# Binary `dev-run-tests` runs bitcoinix's `run-tests.sh` with extra scenarios from ./scenarios.nix
# Example:
# Run command `nodeinfo` in `myscenario` (defined in ./scenarios.nix) via a container
dev-run-tests -s myscenario container --run c nodeinfo

# Equivalent (shorthand)
te -s myscenario container --run c nodeinfo

# Run the tests for `myscenario` in a VM
te -s myscenario

# Start an interactive shell inside a VM
te -s myscenario vm
```

See also: [test/README.md](../test/README.md)

## Adding a new service

It's easiest to use an existing service as a template:
- [electrs.nix](../modules/electrs.nix): a basic service
- [clightning.nix](../modules/clightning.nix): simple, but covers a few more features.\
  (A CLI binary and a runtime-composed config to include secrets.)
- [mempool.nix](../modules/mempool.nix): includes custom packages, defined in [pkgs/mempool](../pkgs/mempool).\
  Most other services use packages that are already included in nixpkgs.

For generated configs in writable service directories, use `install -T` with an
explicit mode to replace the config path, including symlinks to directories.
The `config-replace` test in [suite/restarts.py](../test/suite/restarts.py) covers symlinks to files
and directories for Bitcoin Core, Core Lightning, LND, NBXplorer, electrs, and mempool. It
checks the config's owner and mode after restart and verifies that the symlink
targets remain unchanged.

See [the test execution phases](../test/README.md#execution-phases) before adding
or moving a test. Configuration defaults and invalid option combinations can
be covered by the [checks without a VM](../test/README.md#checks-without-a-vm).

## Updating dependencies

Run `helper/update-flake.sh` to update all flake inputs. It also regenerates
[`versions.json`](../versions.json), which maps each pinned package name to its
selected `version` and nixpkgs `channel` (`unstable`). Versioned local
packages exported by the flake are also included, with `channel` set to `local`.

Nixpkgs service packages and their overrides are selected in the `pinned`
attribute set in [`pkgs/default.nix`](../pkgs/default.nix). The manifest reads
their versions directly from that selection.

`nbPython3Packages` uses `pkgs.python3Packages` from the single unstable package set, including `pyln-bolt7`,
`pyln-client`, `pyln-proto` and `pylightning`. Python Core Lightning plugins use
the matching unstable interpreter and dependencies. Trezor also uses this package
set. HWI uses the separate package set with the ECDSA exception in
[`pkgs/python-packages/default.nix`](../pkgs/python-packages/default.nix).

After changing a local package version, regenerate the manifest without updating
flake inputs:

```bash
nix eval --json -f helper/update-flake.nix versionsFile | jq . > versions.json
helper/gen-docs-versions.sh > docs/versions-table.md
```

The second command regenerates the package versions table that
[`docs/introduction.md`](../docs/introduction.md) includes. When you add a package to
`versions.json`, add its release link to `helper/gen-docs-versions.sh`; the script fails
without it.

CI checks that `versions.json` matches the selected nixpkgs and local packages, and that the docs table
matches `versions.json`. Run
`./test/ci/check-versions.sh` to check it locally without updating dependencies.

To regenerate after changing input declarations without updating other locked inputs,
run `helper/update-flake.sh -f --refresh`.

After updating unstable nixpkgs, check treewide whether any `TODO-EXTERNAL`
comments can be resolved. Keep existing `system.stateVersion` values when upgrading;
they control state compatibility, not the package channel.

## Cutting a release

A release is a signed, annotated git tag and nothing else. There are no release archives
and no GitHub release assets. Signing needs the maintainer's key, so this cannot run in CI.

Before tagging, review the draft files under `docs/release-notes/<version>/`
and make sure they cover notable changes, including package and flake-attribute changes.
Breaking module or service changes also need an entry in
`modules/versioning/<version>/<identifier>.nix`, with non-trivial migrations documented in
[the upgrading guide](../docs/upgrading.md).
During development, put each change in its own file under
`docs/release-notes/<version>/` or `docs/upgrading/<version>/`, using a descriptive,
lowercase, hyphen-separated filename and a fourth-level heading (`#### <title>`).
The **first draft PR for a milestone** also opens its version pages. After writing
the draft, run the helper with the version chosen for the milestone and commit
its output in the same PR.

```bash
nix shell --inputs-from . nixpkgs#python3 -c helper/open-release-notes.py <version>
```

The helper creates `# Release notes <version>` and `# Upgrading to config version <version>`
pages. Each starts with a `TBD.` paragraph and links to the drafts on GitHub.
The upgrade page tells readers to keep the latest released `configVersion` during
development. The helper adds both pages to their indexes and to `docs/SUMMARY.md`.
It can be rerun to restore missing entries. Subsequent draft PRs add only their
own files. Earlier releases keep their consolidated pages at
`docs/release-notes/<version>.md` and `docs/upgrading/<version>.md`. Edit those
pages only to fix errors.

At release time, consolidate the Markdown files in the release-preparation commit:

1. Replace the TBD contents of the two version pages. Concatenate
   `docs/release-notes/<version>/*.md` into
   `docs/release-notes/<version>.md`, headed `# Release notes <version>`, and
   `docs/upgrading/<version>/*.md` into `docs/upgrading/<version>.md`, headed
   `# Upgrading to config version <version>`. Keep a blank line between entries.
   Group related changes and put prerequisite migrations first. Preserve each
   draft's heading on its corresponding page.
2. Adjust relative links for the new parent directory. Replace all links to
   individual change files with links to their headings in the consolidated pages,
   including links from release notes to upgrade notes. Check references in
   `README.md`, `docs/`, `examples/`, `modules/` and `helper/`.
3. End the upgrade page with the instruction to set
   `nix-bitcoin.configVersion = "<version>";` after completing the migrations.
   Remove the development-only instruction to keep the previous config version.
4. Remove the `(upcoming)` labels from the version links in `docs/release-notes.md`
   and `docs/upgrading.md`.
5. Remove the consolidated Markdown fragments and their now-empty version
   directories. Leave `modules/versioning/<version>/*.nix` separate.

CI and the signing helper check the version pages, navigation and draft headings.
They reject headings that have lost their entry text and build the book to check
link targets and anchors both on the consolidated pages and in links to them
from other chapters. If a PR misses its release, move its Markdown drafts
and any new Nix migration notices to the next open milestone before merging it.
CI checks new notice paths against the finalized version on the target branch.
To run the same documentation check locally after committing release preparation, use
`nix shell --inputs-from . nixpkgs#{cmark,mdbook,python3} -c bash helper/check-release-notes.sh <version>`.

Root [`version.nix`](../version.nix) records the latest finalized release. **Do not
change it during development, including when adding migration notices.** Once the
migration list is final, merge a release-preparation commit that updates:

- `version.nix` to `<version>`.
- `configVersion` in `examples/configuration.nix` and
  `examples/{flakes,colmena,container}/flake.nix` to `<version>`.
- The bitcoinix input pins in those three flakes to `v<version>`.
- The consolidated release and upgrade pages, their links and navigation, and the
  upgrade page's final `configVersion` instruction, as described above.

The release helper requires `HEAD` to equal `origin/master`, so this preparation
commit must be on master before tagging. Until the tag is pushed, the example
flakes on master reference a tag that cannot yet be fetched. The example tests
override these pins with the checkout and can still run during this interval.

Advancing `version.nix` turns that release's migration warnings into
blocking errors. Keep each example's value as an explicit one-line assignment;
importing `version.nix` would acknowledge migrations automatically in user
configurations. Run
`nix flake check --all-systems` and the [release-helper tests](../test/README.md#checks-without-a-vm),
then tag the prepared commit. Later migrations must go in the next release's directory.

```bash
helper/make-release.sh <version>    # e.g. 0.1.0, without the leading "v"
git push origin v<version>          # manual, the script never pushes
```

One-time setup:

```bash
git config gpg.format ssh
git config user.signingkey <path to your public key>
```

and your key must be listed in
[`helper/release-keys/ssh-allowed-signers`](../helper/release-keys/ssh-allowed-signers).

Before signing, the script checks that:

- you are on `master`, with no uncommitted changes to tracked files, and `HEAD` equals
  `origin/master`
- tag `v<version>` exists neither locally nor on `origin`
- `<version>` is a stable `X.Y.Z` that is greater than every existing release tag
- `version.nix` and all four examples' `configVersion` values equal `<version>`,
  and the three example flakes pin `v<version>`
- each draft heading appears on the corresponding version page, including when
  consolidation and the version bump are separate commits
- the pages have their release titles, working book links and navigation entries,
  the upgrade page ends with the new `configVersion` instruction, and the
  finalized version has no draft files, TBD paragraphs or upcoming labels
- `gpg.format` is `ssh`, `user.signingkey` is set and the allowed signers file exists

It then creates the signed tag and verifies it with `helper/fetch-release.sh`, the same
check users run, against your local repository. If verification fails, it deletes the
tag it just created. Finally it prints the `git push` command, how to undo the tag
before pushing, and the post-release checks. Pass `-y` to skip the confirmation prompt.

After pushing, `checkDownload=1 releaseVersion=<version> helper/fetch-release.sh` run from a clean
clone verifies the pushed tag and then downloads the archive that Nix users will get, into a
throwaway store and cache so that nothing local can satisfy it. It fails unless the archive
is exactly the signed tree. For a fork, also set `repoUrl=https://github.com/<owner>/<repo>`.

Tag names must match `^v[0-9]+\.[0-9]+\.[0-9]+$`; `helper/fetch-release.sh` ignores anything else.
Pre-releases such as `0.1.0-rc1` are not supported.

The repository must not contain a `.gitattributes` file (at any depth). `fetch-release.sh`
hashes the tree from `git archive`, and attributes such as `export-subst` can make that differ
from the archive GitHub serves, so it refuses such a release.

The verification step is the one that matters: it fails if the tag was signed with a key
that is not listed in `ssh-allowed-signers`, which is the most likely way to publish an
unverifiable release. `.github/workflows/release.yml` repeats it for the latest release tag,
the one `fetch-release.sh` picks by default, on each tag push and daily, with
`fetch-release.sh`, the key files and the flake lock taken from `master`, never from the tag.
Older tags are not re-checked: release tags are protected, so they cannot change, and tags
signed by a later revoked key would otherwise fail every run. A tag push runs the workflow file
from the pushed tag, so only the daily (or a manual) run is a check that a malicious tag cannot
alter. A failing daily run means the latest release no longer verifies, e.g. after its key
was revoked: cut a new release signed by a valid key. The same workflow flags `v*` tags that
are not `vX.Y.Z`.

To add or retire a maintainer key, edit `helper/release-keys/ssh-allowed-signers` and
`SECURITY.md` together; `test/release-keys-test.sh` fails if the two drift apart. Retire a
key by appending `valid-before="YYYYMMDD"` to its line rather than deleting it, so that tags
signed while it was still valid keep verifying. That is only safe for a key that is not
compromised: `valid-before` is checked against the tag's own date, which the signer chooses.
Add a compromised key to `helper/release-keys/ssh-revoked-keys` instead (and keep its line in
`ssh-allowed-signers`); every tag it signed is then rejected. See SECURITY.md.

`.github/CODEOWNERS` assigns the release-signing files (the key files, `fetch-release.sh`,
`make-release.sh`, both `check-release-notes` files, `release.yml` and `SECURITY.md`) to the
maintainers. It only has an effect if a branch protection rule (or ruleset) on `master`
requires review from code owners, which is a repository setting made in GitHub. Code
owners need write access to the repository, otherwise GitHub ignores them. With two
maintainers listed, a change by one of them needs the other's approval.
