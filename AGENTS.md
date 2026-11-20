# AGENTS.md

NixOS modules + Nix packages for deploying security-focused Bitcoin/Lightning nodes.
This is `bitcoinix`, a community fork of the archived `fort-nix/nix-bitcoin`
(fork point tagged `forked` in history). Remote: `git@github.com:bitcoinix/bitcoinix.git`,
default/base branch `master`. Fork policy leans toward removing/decoupling
unmaintained services — check before assuming an upstream service stays.
Option namespaces and internal names stay `nix-bitcoin.*`; don't rename them to
`bitcoinix` (breaks existing user configs). `docs/` is the user guide, built with mdBook
(`book.toml`, favicon in `theme/`; `docs/SUMMARY.md` lists the pages). Pages with the
"inherited from nix-bitcoin" banner have not been reviewed yet.

## AI-assisted contributions

Commits made with assistance from LLM-based AI tooling **must** include an
`Assisted-by:` Git commit trailer naming at least the tool and the primary model
name and version used for the contribution. A `Co-authored-by:` trailer does not
satisfy this policy.

## Commands

All work happens through the flake. Nix is required (flakes enabled).
Run the commands below in a supported Linux environment; for a Mac host, see
the next section before trying `nix develop` or builds.

```bash
nix develop                 # shell with run-tests.sh + helper/* on PATH
nix flake check --all-systems
./test/shellcheck.sh        # shellchecks every .sh and shebang'd extensionless file
nix run nixpkgs#mdbook -- build   # build the docs into ./book (gitignored)
nix run nixpkgs#mdbook -- serve   # serve the docs locally with live reload
# build the docs with the module option list, as published
nix shell --inputs-from . nixpkgs#{git,mdbook,python3} -c python3 helper/docs/build.py book
```

Build/run a node VM: `nix run .` (alias for `.#vm`).

## macOS hosts

- macOS can host development, but the flake only provides `x86_64-linux` and
  `aarch64-linux` outputs. Do not add Darwin outputs or change `supportedSystems`
  to make a local build work. `--system aarch64-linux` alone supplies no Linux builder.
- Check `uname -sm` and `command -v orb`. If `orb` is installed, prefer an
  OrbStack Linux machine; inspect `orb list` and reuse a suitable machine with Nix.
  Otherwise use Docker. Setup and noninteractive commands are in
  [dev/macos.md](dev/macos.md); Nix on the Mac itself is optional.
- Default OrbStack machines expose Mac files, macOS commands, and the SSH agent.
  For untrusted PRs, use an isolated machine with a Linux-local clone, or Docker
  with a disposable checkout and separate store; see the guide's isolation steps.
- Prefer `aarch64-linux` on Apple Silicon and `x86_64-linux` on Intel. Run from
  the checkout containing the revision and edits being tested. An isolated
  machine's clone does not include edits from the Mac checkout automatically.
- Start with the lightweight flake checks and relevant package builds. VM test
  builds require usable KVM inside Linux; a successful package build or flake
  check does not mean VM integration tests ran. Report these separately and state
  any unavailable checks. See [test/README.md](test/README.md#checks-without-a-vm).

## Tests (primary dev loop)

`./test/run-tests.sh` is the main tool; requires Nix flakes and leaves no host
traces outside `/nix/store`.

- Scenarios live in `test/tests.nix` (plus extras from `dev/dev-scenarios.nix`).
  `baseConfig` maps enabled services to `tests.<name> = cfg.<svc>.enable`.
- Python test bodies are registered with `@test("<name>")` in `test/suite/`.
  `TEST_PHASES` in `test/tests.py` defines their execution order; add each new
  built-in test there too. See `test/README.md` for phase contracts. A
  `tests.<name>` enabled in Nix without a matching `@test` raises before tests run.
- Fast checks live in `test/configuration.nix` (module evaluation) and
  `test/runner-tests.py` (runner behavior), exposed via flake `checks`.

```bash
./test/run-tests.sh                        # `basic` = default netns netnsRegtest
./test/run-tests.sh -s regtest build       # one scenario, via Nix build (cached)
./test/run-tests.sh -s clightning          # adhoc scenario: enables services.clightning
./test/run-tests.sh -s bitcoind vm         # boot VM, no tests run
./test/run-tests.sh debug                  # Python NixOS-test REPL
sudo ./test/run-tests.sh container          # fast container; needs systemd + root
./test/run-tests.sh container --run c journalctl -u electrs
./test/run-tests.sh -s '<nix expr>'        # inline scenario when arg has spaces
```

- No scenario + explicit command ⇒ `default`; no args at all ⇒ the `basic` set.
- `run-tests.sh` targets: `build vm debug container eval shellcheck flake examples
  deploymentExamples all`.
- `--copy-src` snapshots the source so edits during a run don't affect it.
- CI (`.github/workflows/test.yml`, PRs + pushes to `master`) runs the `basic`
  scenarios, `nix flake check --all-systems`, `test/nixos-search/ci-test.sh`,
  `test/ci/deployment-examples.sh`, and shellcheck. Builds are cached in the `bitcoinix` Cachix cache. The rulesets on `master`
  and release tags require the `ci_gate` job; add any new CI job to its `needs`.
- Documentation-only PRs skip VM, deployment-example and nixos-search jobs; see
  `test/README.md#ci-scheduling-and-caching`. Fast checks still run.
- Docs (`.github/workflows/docs.yml`) are only build-checked on PRs. https://docs.bitcoinix.net
  is published from the latest verified release tag, after "Verify release tags"
  succeeds for a pushed tag (or manually), never from `master`. Docs changes on `master`
  go live with the next release, so `docs/` must describe the upcoming release.
  `helper/docs/build.py site` serves the latest release at `/` and each release from
  0.1.6 on at `/v/<version>/`; keep page URLs at `/` stable, code and old docs link
  to them. Releases build with the master tooling, so keep it compatible with them.
- `dev/` holds debugging helpers (`dev.sh`, `dev-features.sh`, `topics/`); see `dev/README.md`.

## Architecture

- `flake.nix` is the entrypoint: exposes `nixosModules.default`, `lib.mkNbPkgs`,
  `packages`/`legacyPackages`, `tests.*`, and `devShells.default`.
- `modules/modules.nix` is the module entrypoint and is **topologically sorted by
  dependency** — order matters; register new service modules in the right group.
- `pkgs/` defines derivations; `pkgs/lib.nix` holds shared security hardening
  (systemd sandboxing, user/isolation helpers) used across services.
- The single `nixpkgs` input tracks `nixos-unstable`. `nix-bitcoin.useVersionLockedPkgs`
  defaults to true and selects the flake's pinned unstable nixpkgs for services.
- Always update `flake.lock` via `helper/update-flake.sh`; never hand-edit it or
  run `nix flake update` / `nix flake lock` directly. The helper keeps
  `versions.json` and `docs/versions-table.md` in sync with the locked inputs.
- `pkgs/default.nix` selects nixpkgs service packages in its `pinned` attribute set
  and applies local overrides. The version manifest reads this selection directly.
- Only `x86_64-linux` and `aarch64-linux` are supported and tested.
- No Nix formatter/linter is set up; `nix flake check` and `./test/shellcheck.sh`
  are the static checks. Shellcheck also covers shebang'd extensionless files.

## Deployment examples

`examples/flakes` (`nixos-rebuild --flake`) and `examples/colmena` are the supported
deployment examples; krops (`examples/krops`) is legacy. The CI job `deployment_examples`
builds each of them with its own tool against the checkout on PRs with code changes, via
`test/ci/deployment-examples.sh` (locally: `./test/run-tests.sh deploymentExamples`).
The other examples (`examples/deploy-*.sh`, `examples/container`) run only with
`./test/run-tests.sh examples`, not in CI.
A new deployment example must be added to that script, the version checks in
`helper/make-release.sh`, and the `deployment_examples` job, so CI tests it from the start.
The supported deployment flakes name the main input `bitcoinix`, pin a release tag,
set that release's `configVersion` and commit no `flake.lock`; the script overrides
the `bitcoinix` input and uses the
checkout's root `version.nix` for `configVersion`.

## Adding a service module

Start from an existing module: `modules/electrs.nix` (basic) →
`modules/clightning.nix` (CLI binary, runtime-composed config with secrets) →
`modules/mempool.nix` (bundles custom packages under `pkgs/`). Register it in
`modules/modules.nix`. Other integration points to wire up:

- `modules/netns-isolation.nix`: unique netns `id` + `connections` to other services.
- Secrets: declare in `nix-bitcoin.secrets`, order the unit after `nix-bitcoin-secrets.target`.
- Tor: `modules/onion-services.nix` / `nix-bitcoin.onionServices`.
- Tests: `tests.<name>` in `test/tests.nix` + `@test` in `test/suite/` + a place in
  `TEST_PHASES` in `test/tests.py`.

## Removing a service

Delete the module (and its `pkgs/` entries), drop it from `modules/modules.nix`,
and add a `mkRemovedOptionModule` with the reason to `modules/obsolete-options.nix`
(the joinmarket entries are the template). Then purge it from `test/tests.nix`,
`test/suite/`, the execution plan in `test/tests.py`, `test/configuration.nix`,
`flake.nix`, `examples/`, and `docs/`.

## Breaking changes

Any change that breaks functionality from the user's point of view **must** add an
entry in `modules/versioning/<version>/<identifier>.nix`, so users hit it at evaluation time
when they update. A release note alone is not enough. This includes:

- a removed or renamed option, or a removed module/service (also add a
  `mkRemovedOptionModule`, see "Removing a service")
- a changed default that changes behaviour, e.g. a listen address (the 0.1.0
  lndconnect entry)
- required manual action or downtime: a database/index reindex or resync (the electrs
  entries), a data migration
- data no longer covered by a service, e.g. backups (the 0.1.1 Liquid entry)
- something that used to work and now fails at runtime, e.g. a permission, RPC method
  or sandboxing restriction

The exception is changes confined to package or flake attributes, with no change to
module configuration or service behavior: document these in
`docs/release-notes/<version>/<title>.md` for the upcoming release.
Do not add a config-version notice or bump solely for these changes.

Root `version.nix` records the latest finalized release. **Change it only when
preparing a release immediately before tagging, never during development.**
Unreleased notices warn without blocking deployment or requiring acknowledgement;
users must review them before deploying. Released notices block until acknowledged
with the user's `configVersion`. Values newer than `version.nix` are rejected.
An unset `configVersion` disables migration notices. Removed-option errors and other
service assertions are independent of this policy.

For each entry:

- `<version>` is the next release: the lowest open
  [GitHub milestone](https://github.com/bitcoinix/bitcoinix/milestones). Most releases
  bump only the last component; a release with bigger changes bumps the second one
  (0.1.6 → 0.2.0). The maintainers decide this by creating the milestone, so don't
  derive the version from the latest tag alone. Choose a short,
  descriptive `<identifier>` for each change; several files per version are fine.
  Each file is a function taking `{ config, options, lib, ... }` (only declare the
  arguments it uses) and returning `{ condition = ...; message = ...; }`.
  `modules/versioning.nix` supplies the version from the directory name and loads
  notices in increasing version order, then alphabetically by filename. It appends
  a reference to `docs/upgrading/<version>/` while the draft directory exists,
  then to `docs/upgrading/<version>.md` after consolidation. It falls back to
  `docs/upgrading.md` for versions starting at 0.1.0 without either path.
- Set `condition` so only affected users see it, e.g. users who already set the
  new value don't.
- The `message` says what changed and what to do. Put longer migration steps in
  `docs/upgrading/<version>/<title>.md`; the message does not need to repeat
  the reference to the upgrade notes.
- Keep `version.nix` and all examples' `nix-bitcoin.configVersion` at the latest
  released version while adding changes or migration notices. Advance both only
  when finalizing the migration list immediately before tagging
  (see "Cutting a release" in `dev/README.md`). Later notices go in the next release.
  Keep each example's version as an explicit one-line assignment for the release
  helper to check; never import `version.nix` into user `configVersion` settings,
  which would acknowledge migrations automatically.
  In that same preparation commit, update the bitcoinix release pins in
  `examples/{flakes,colmena,container}/flake.nix` together with their `configVersion`.
  The release helper checks all four versioned examples before tagging. CI uses
  the checkout and `version.nix`, so the new tag need not exist yet.

## Documentation

On every change, re-check whether the docs (`README.md`, `docs/`, `dev/README.md`,
`examples/`) are affected. Not every change needs a docs update, but a significant
new feature or a behaviour change MUST be reflected in the docs, in the same PR.
Pages under `docs/` must be listed in `docs/SUMMARY.md` to appear in the mdBook build.
The option list in `docs/options.md` is generated from the option declarations
(`legacyPackages.<system>.docsOptions`, `helper/docs/options.nix`); describe options
in their `description`, not in that page.

- During development, keep each change in a separate Markdown file to avoid merge
  conflicts, like the notices in `modules/versioning/<version>/`. Use descriptive,
  lowercase, hyphen-separated filenames (`<title>.md`) and start each file with
  a fourth-level heading (`#### <title>`). CI checks the heading and requires
  drafts to be `.md` files directly inside the version directory. The indexes
  and `docs/SUMMARY.md` list only the version pages. In the PR adding the first
  draft for a milestone, run `helper/open-release-notes.py <version>` and
  commit the two TBD pages and navigation entries it creates. Subsequent
  drafts need only their own files. CI checks that both pages are linked
  from the indexes and sidebar and rejects links there to individual drafts. If a PR
  misses its release, move its drafts and any new Nix migration notices to the
  next open milestone. CI checks new notice paths against the base branch's
  finalized version and rejects draft files or TBD pages for finalized versions.
- Release notes: record notable changes, including package and flake-attribute
  changes, in `docs/release-notes/<version>/<title>.md`. Link to the corresponding
  upgrade note for configuration migrations instead of duplicating their steps.
- Upgrade notes: every entry under `modules/versioning/` with a non-trivial migration
  gets text in `docs/upgrading/<version>/<title>.md`. Keep the explanation and
  migration steps together in that file. The TBD upgrade page tells users
  following master to keep the latest released `configVersion` until the upcoming
  release is finalized.
- `docs/release-notes.md` and `docs/upgrading.md` are indexes and explain the layout.
  Released versions have one concatenated page each at
  `docs/release-notes/<version>.md` and `docs/upgrading/<version>.md`, linked newest
  first. Edit released pages only to fix errors.
- At release time, replace the TBD contents of the two per-version pages with
  the consolidated draft notes in the release-preparation commit. Preserve each
  draft's heading and text together. CI and the signing helper compare the text
  under each heading, allowing rebased link destinations. End the upgrade page
  with the instruction to set `nix-bitcoin.configVersion = "<version>";` after migrating.
  Rebase relative links, replace links to individual files with links
  to the matching headings in the consolidated pages, drop the upcoming labels
  from both indexes, and remove the individual Markdown files. Keep the Nix notices in
  `modules/versioning/<version>/` separate. See "Cutting a release" in
  `dev/README.md` for the full procedure.
- Removed or renamed options, commands, paths and services: grep `README.md`, `docs/`
  and `examples/` and update or remove every mention. Docs must not describe features
  that no longer exist.
- Code that points into the docs must stay valid when a page or heading moves:
  `modules/versioning/`, `modules/obsolete-options.nix`, runtime messages (e.g.
  `modules/electrs.nix`), `helper/makeShell.nix`, `examples/` and `README.md`.
- Only document what the code does; check option names, defaults, paths and commands
  against the modules. Keep pages short and task-oriented and link to the module
  source or the options search for details.

## Nixpkgs updates

`./helper/update-flake.sh`, then treewide re-check `TODO-EXTERNAL` comments.
