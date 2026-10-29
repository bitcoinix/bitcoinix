# Building from macOS

bitcoinix supports `x86_64-linux` and `aarch64-linux`. You can edit on macOS and
build the same checkout in Linux. Prefer OrbStack if `command -v orb` succeeds;
use Docker otherwise. Neither route requires Nix installed on macOS.

The examples target **Apple Silicon (`aarch64-linux`)**. On an Intel Mac, use
`x86_64-linux` in Nix attributes and `linux/amd64` for Docker, with a separate
volume named `bitcoinix-nix-amd64`. Prefer the guest's native architecture;
`--system` selects a Nix target but does not provide a Linux builder or emulation.

## OrbStack (preferred)

From the repository root on the Mac, inspect existing machines:

```bash
orb list
```

Reuse a suitable Linux machine with Nix if available, replacing `bitcoinix` below
with its name. Otherwise create one; the default architecture matches the Mac:

```bash
orb create ubuntu bitcoinix
```

For a fresh Ubuntu machine, install prerequisites and
[Nix with its multi-user installer](https://nix.dev/manual/nix/stable/installation/installing-binary.html).
These commands install inside Linux:

```bash
orb -m bitcoinix sudo apt-get update
orb -m bitcoinix sudo apt-get install -y ca-certificates curl git xz-utils
orb -m bitcoinix bash -lc '
  curl -fsSL https://nixos.org/nix/install -o /tmp/install-nix &&
  sh /tmp/install-nix --daemon --yes
'
```

Define this helper in the Mac shell, from the repository root. It selects the
machine explicitly, loads the Linux login environment, enables flakes, and runs
each command in the current checkout. It also works without a terminal for agents:

```bash
nb() {
  orb -m bitcoinix bash -lc '
    export NIX_CONFIG="experimental-features = nix-command flakes"
    cd "$1" && shift && exec "$@"
  ' bash "$PWD" "$@"
}
```

OrbStack [shares Mac paths with Linux](https://docs.orbstack.dev/machines/file-sharing),
so edits and Git metadata remain available at the same paths. The machine keeps
its own `/nix` store between commands. See the
[OrbStack command reference](https://docs.orbstack.dev/machines/commands) for
machine management. Continue with [Build and check](#build-and-check).

## Docker fallback

Use this when OrbStack is unavailable and a local Docker engine is running
(`docker info`). From the repository root on the Mac, define this alternative
`nb` helper:

```bash
nb() {
  docker run --rm --platform linux/arm64 \
    --mount type=volume,src=bitcoinix-nix-arm64,dst=/nix \
    --mount "type=bind,src=$PWD,dst=$PWD" \
    --workdir "$PWD" \
    --env 'NIX_CONFIG=experimental-features = nix-command flakes' \
    ghcr.io/nixos/nix:2.35.4 \
    bash -c 'git config --global --add safe.directory "$PWD" && exec "$@"' bash "$@"
}
```

The [official Nix image](https://github.com/NixOS/nix/pkgs/container/nix) has
ARM64 and AMD64 variants. The named volume preserves the Linux store, database,
and profiles across disposable containers; do not bind-mount the Mac's `/nix`.
Docker [initializes an empty volume from the image](https://docs.docker.com/engine/storage/volumes/).
Use a new volume when changing the image version so it starts with that image's
Nix installation. The `safe.directory` setting trusts only this checkout inside
the disposable container, whose user may differ from the Mac file owner.

For a linked Git worktree, also bind-mount its main repository's Git directory
(shown by `git rev-parse --git-common-dir`) at the same absolute path inside the
container, so the worktree's `.git` pointer resolves. Mounting only the worktree
is insufficient. Keep the checkout writable for commands that generate files.
The helper omits `-it` for automation; add it to `docker run` for an interactive shell.

## Build and check

Run from the repository root on the Mac after defining either helper:

```bash
# Confirm Linux Nix and access to the checkout being edited.
nb nix eval --impure --raw --expr builtins.currentSystem  # Expect aarch64-linux
nb git status --short

# Evaluate module contracts, then build the lightweight checks (no KVM needed).
nb nix eval .#checks.aarch64-linux.module-config.testCount
nb nix build --no-link \
  .#checks.aarch64-linux.module-config \
  .#checks.aarch64-linux.test-runner \
  .#checks.aarch64-linux.cve-tools

# Build a package, replacing clnrest with the package being changed.
nb nix build --no-link .#packages.aarch64-linux.clnrest

# Evaluate all supported outputs and run checks for the guest's system.
nb nix flake check --all-systems
nb ./test/shellcheck.sh
```

Nix uses tracked files and their current edits; add intended new files to Git
before checking them. `--no-link` avoids creating a `result` symlink into a Linux
store that the Mac cannot use directly. Run Linux build outputs through `nb` too.
For a dev shell, use `nb nix develop` (with `-it` for the Docker helper).

## VM tests

`./test/run-tests.sh -s regtest build` **executes a VM test**, not just a package
build. Its derivation requires `kvm` and `nixos-test` system features. Check for
accessible KVM in the Linux guest before attempting it:

```bash
nb sh -c 'test -r /dev/kvm && test -w /dev/kvm'
```

KVM availability depends on the Mac and virtualization backend; these setup
instructions do not provide it. If it is unavailable, run the lightweight checks
and package builds above, and leave VM integration tests to a Linux builder with
KVM or CI. Do not advertise `kvm` in Nix configuration to bypass a missing device.
The `container` test target instead needs Linux with systemd and root privileges;
the Docker Nix image does not provide a booted systemd environment.

Report package/check results separately from VM tests, including any tests that
could not run. See [test/README.md](../test/README.md) for the full test workflow.
