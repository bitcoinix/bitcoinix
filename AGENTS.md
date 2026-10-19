# AGENTS.md

NixOS modules + Nix packages for deploying security-focused Bitcoin/Lightning nodes.
This is `bitcoinix`, a community fork of the archived `fort-nix/nix-bitcoin`
(fork point tagged `forked` in history). Remote: `git@github.com:bitcoinix/bitcoinix.git`,
default/base branch `master`. Fork policy leans toward removing/decoupling
unmaintained services — check before assuming an upstream service stays.
Option namespaces and internal names stay `nix-bitcoin.*`; don't rename them to
`bitcoinix` (breaks existing user configs). `docs/` is largely inherited from nix-bitcoin
and is built with mdBook (`book.toml`; `docs/SUMMARY.md` lists the pages).

## AI-assisted contributions

Commits made with assistance from LLM-based AI tooling **must** include an
`Assisted-by:` Git commit trailer naming at least the tool and the primary model
name and version used for the contribution. A `Co-authored-by:` trailer does not
satisfy this policy.

## Commands

All work happens through the flake. Nix is required (flakes enabled).

```bash
nix develop                 # shell with run-tests.sh + helper/* on PATH
nix flake check --all-systems
./test/shellcheck.sh        # shellchecks every .sh and shebang'd extensionless file
nix run nixpkgs#mdbook -- build   # build the docs into ./book (gitignored)
nix run nixpkgs#mdbook -- serve   # serve the docs locally with live reload
```

Build/run a node VM: `nix run .` (alias for `.#vm`).

## Tests (primary dev loop)

`./test/run-tests.sh` is the main tool; requires Nix flakes and leaves no host
traces outside `/nix/store`.

- Scenarios live in `test/tests.nix` (plus extras from `dev/dev-scenarios.nix`).
  `baseConfig` maps enabled services to `tests.<name> = cfg.<svc>.enable`.
- Python test bodies are registered with `@test("<name>")` in `test/tests.py` and run
  in definition order. A `tests.<name>` enabled in Nix without a matching `@test`
  raises at runtime — keep both sides in sync.

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
- `run-tests.sh` targets: `build vm debug container eval shellcheck flake examples all`.
- `--copy-src` snapshots the source so edits during a run don't affect it.
- CI (`.github/workflows/test.yml`, PRs + pushes to `master`) runs the `basic`
  scenarios, `nix flake check --all-systems`, `test/nixos-search/ci-test.sh`, and
  shellcheck. Builds are cached in the `bitcoinix` Cachix cache. The rulesets on `master`
  and release tags require the `ci_gate` job; add any new CI job to its `needs`.
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
- Only `x86_64-linux` and `aarch64-linux` are supported. 32-bit was dropped for
  `pymemcache` (a joinmarket dep); joinmarket is now removed, so the rationale in
  `flake.nix` is stale.
- No Nix formatter/linter is set up; `nix flake check` and `./test/shellcheck.sh`
  are the static checks. Shellcheck also covers shebang'd extensionless files.

## Adding a service module

Start from an existing module: `modules/electrs.nix` (basic) →
`modules/clightning.nix` (CLI binary, runtime-composed config with secrets) →
`modules/rtl.nix` (bundles a custom package under `pkgs/`). Register it in
`modules/modules.nix`. Other integration points to wire up:

- `modules/netns-isolation.nix`: unique netns `id` + `connections` to other services.
- Secrets: declare in `nix-bitcoin.secrets`, order the unit after `nix-bitcoin-secrets.target`.
- Tor: `modules/onion-services.nix` / `nix-bitcoin.onionServices`.
- Tests: `tests.<name>` in `test/tests.nix` + `@test` in `test/tests.py`.

## Removing a service

Delete the module (and its `pkgs/` entries), drop it from `modules/modules.nix`,
and add a `mkRemovedOptionModule` with the reason to `modules/obsolete-options.nix`
(the joinmarket entries are the template). Then purge it from `test/tests.nix`,
`test/tests.py`, `flake.nix`, `examples/`, and `docs/`.

## Breaking changes

Any change that breaks functionality from the user's point of view **must** add an
entry to `changes` in `modules/versioning.nix`, so users hit it at evaluation time
when they update. A release note alone is not enough. This includes:

- a removed or renamed option, or a removed module/service (also add a
  `mkRemovedOptionModule`, see "Removing a service")
- a changed default that changes behaviour, e.g. a listen address (the 0.1.1
  clightning-rest entry)
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
  `docs/configuration.md` under "Upgrading to config version <version>" and link them.
- Set `nix-bitcoin.configVersion` in `examples/configuration.nix` to that version
  unless it already is.

## Documentation

On every change, re-check whether the docs (`README.md`, `docs/`, `dev/README.md`,
`examples/`) are affected. Not every change needs a docs update, but a significant
new feature or a behaviour change MUST be reflected in the docs, in the same PR.
Pages under `docs/` must be listed in `docs/SUMMARY.md` to appear in the mdBook build.

## NixOS release bumps

`./helper/update-flake.sh 26.05`, then treewide re-check `TODO-EXTERNAL` comments.
