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
- Prefer `aarch64-linux` on Apple Silicon and `x86_64-linux` on Intel. Run from
  the current checkout inside Linux so builds include the edits being tested.
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
- Docs (`.github/workflows/docs.yml`) are only build-checked on PRs. https://docs.bitcoinix.net
  is published from the latest verified release tag, after "Verify release tags"
  succeeds for a pushed tag (or manually), never from `master`. Docs changes on `master`
  go live with the next release, so `docs/` must describe the upcoming release.
- `dev/` holds debugging helpers (`dev.sh`, `dev-features.sh`, `topics/`); see `dev/README.md`.

## Architecture

- `flake.nix` is the entrypoint: exposes `nixosModules.default`, `lib.mkNbPkgs`,
  `packages`/`legacyPackages`, `tests.*`, and `devShells.default`.
- `modules/modules.nix` is the module entrypoint and is **topologically sorted by
  dependency** — order matters; register new service modules in the right group.
- `pkgs/` defines derivations; `pkgs/lib.nix` holds shared security hardening
  (systemd sandboxing, user/isolation helpers) used across services.
- nixpkgs is pinned to `nixos-26.05`, plus a `nixpkgs-unstable` input for pinned
  packages. `nix-bitcoin.useVersionLockedPkgs` opts a system
  into the flake's pinned nixpkgs.
- `pkgs/pinned.nix` is **generated** by `helper/update-flake.sh` (packages are
  pinned to stable vs. unstable by version comparison) — don't hand-edit it.
- Only `x86_64-linux` and `aarch64-linux` are supported and tested.
- No Nix formatter/linter is set up; `nix flake check` and `./test/shellcheck.sh`
  are the static checks. Shellcheck also covers shebang'd extensionless files.

## Deployment examples

`examples/flakes` (`nixos-rebuild --flake`) and `examples/colmena` are the supported
deployment examples; krops (`examples/krops`) is legacy. The CI job `deployment_examples`
builds each of them with its own tool against the checkout on every PR, via
`test/ci/deployment-examples.sh` (locally: `./test/run-tests.sh deploymentExamples`).
The other examples (`examples/deploy-*.sh`, `examples/container`) run only with
`./test/run-tests.sh examples`, not in CI.
A new deployment example must be added to that script and get its own step in the
`deployment_examples` job, so that CI tests it from the start. Example flakes name the
main input `bitcoinix`, pin a release tag, set that release's `configVersion` and
commit no `flake.lock`; the script overrides the `bitcoinix` input and `configVersion`.

## Adding a service module

Start from an existing module: `modules/electrs.nix` (basic) →
`modules/clightning.nix` (CLI binary, runtime-composed config with secrets) →
`modules/rtl.nix` (bundles a custom package under `pkgs/`). Register it in
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
entry to `changes` in `modules/versioning.nix`, so users hit it at evaluation time
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

For each entry:

- `version` is the next release (bump only the last component). Append at the end of
  `changes`; several entries per version are fine.
- Set `condition` so only affected users see it, e.g. users who already set the
  new value don't.
- The `message` says what changed and what to do. Put longer migration steps in
  `docs/upgrading.md` under "Upgrading to config version <version>" and refer to
  that section from the message.
- Set `nix-bitcoin.configVersion` in `examples/configuration.nix` to that version
  unless it already is. Leave the deployment examples alone: each one sets the
  `configVersion` of the release it pins, CI builds them with the latest one, and a
  release bumps their pin and `configVersion` together (see "Cutting a release" in
  `dev/README.md`).

## Documentation

On every change, re-check whether the docs (`README.md`, `docs/`, `dev/README.md`,
`examples/`) are affected. Not every change needs a docs update, but a significant
new feature or a behaviour change MUST be reflected in the docs, in the same PR.
Pages under `docs/` must be listed in `docs/SUMMARY.md` to appear in the mdBook build.

- Upgrade notes: every `changes` entry with a non-trivial migration gets text in
  `docs/upgrading.md`. Each version has one `## Upgrading to config version <version>`
  section, newest version first, ending with the line that sets `configVersion`.
  Add to the section of the upcoming release; never edit sections of released versions
  except to fix errors.
- Removed or renamed options, commands, paths and services: grep `README.md`, `docs/`
  and `examples/` and update or remove every mention. Docs must not describe features
  that no longer exist.
- Code that points into the docs must stay valid when a page or heading moves:
  `modules/versioning.nix`, `modules/obsolete-options.nix`, runtime messages (e.g.
  `modules/electrs.nix`), `helper/makeShell.nix`, `examples/` and `README.md`.
- Only document what the code does; check option names, defaults, paths and commands
  against the modules. Keep pages short and task-oriented and link to the module
  source or the options search for details.

## NixOS release bumps

`./helper/update-flake.sh 26.05`, then treewide re-check `TODO-EXTERNAL` comments.
