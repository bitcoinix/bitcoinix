The [`run-tests.sh`](./run-tests.sh) command is the most convenient and versatile way to run tests.\
It leaves no traces (outside of `/nix/store`) on the host system.

`run-tests.sh` requires Nix with [Flakes](https://wiki.nixos.org/wiki/Flakes).

### Summary
```bash
./run-tests.sh [--scenario|-s <scenario>] [build|vm|debug|container]
```

See the top of [run-tests.sh](../test/run-tests.sh) for complete documentation.\
Test scenarios are defined in [tests.nix](./tests.nix). The Python runner and
execution plan are in [tests.py](./tests.py); test bodies and shared helpers are
in [suite/](./suite/).

### Execution phases

Each scenario shares one machine across its enabled tests. `TEST_PHASES` in
[tests.py](./tests.py) defines the order explicitly, independently of where the
test functions live. The split into files preserves the original execution order.

| Phase | Contract |
| --- | --- |
| `services` | Check services, credentials, and connection URLs. Checks that temporarily alter files or restart services restore them before returning. The existing `stop-electrs` exception leaves electrs stopped to silence mainnet logs. |
| `network-and-hardening` | Check namespace reachability and running services' mounts before the disruptive phase stops bitcoind and its dependents. |
| `disruptive` | `backups` stops bitcoind and its dependents. `restart-bitcoind` explicitly starts the units it exercises; `config-replace` starts each unit before testing its generated config. |
| `post-restart` | `regtest` waits for service readiness and synchronization after the restart checks. `lnd-restart-on-clean-exit` follows synchronization; `trustedcoin` checks the plugin's logs. |
| `secrets` | Restart `setup-secrets` and check supplied-secret failures after all service checks, because each run temporarily restricts access to the secrets directory. |
| `extra` | Tests registered by `test.extraTestScript` run last, in registration order, as before. They must account for the preceding service stops and restarts. |

To add a built-in test, define a descriptive function with `@test("name")` in
the appropriate suite file, add its name to `TEST_PHASES`, and enable it with
`tests.name` in Nix. A missing body, unplanned built-in test, or duplicate name
fails before tests run. Adding a new suite file also requires adding it to
[lib/test-script.nix](./lib/test-script.nix).

Phases order enabled tests; they do not enable prerequisites automatically.
Scenarios must enable the checks they depend on. `run_test("name")` in the
debug REPL runs only that test, leaving prerequisites to the caller.

The suite files are assembled in the NixOS driver's shared Python namespace,
so they can use `machine`, `retry`, `enabled_tests`, `test_data`, and the shared
helpers directly. The driver's lint and type checks still see the entire suite.
Use `succeed_json` for JSON responses and `assert_file_metadata` for ownership,
mode, and file-type checks. Shell predicates remain useful with
`machine.wait_until_succeeds` when polling for readiness.

### Checks without a VM

On a Mac, use the [macOS build guide](../dev/macos.md) to run builds in an
OrbStack Linux machine (preferred when `orb` is installed) or Docker. Use
`aarch64-linux` instead of `x86_64-linux` in the commands below for an ARM guest.
Evaluation alone can run on macOS with Nix; building Linux outputs needs a Linux
builder. VM scenarios additionally require usable KVM in that environment.

From the repository root:

```bash
# Evaluate configuration contracts without building packages, including on macOS.
nix eval .#checks.x86_64-linux.module-config.testCount

# Build the lightweight checks on Linux (or using a Linux builder).
nix build --no-link .#checks.x86_64-linux.module-config .#checks.x86_64-linux.test-runner

# Check CVE scan/report behavior without network access or GitHub writes.
nix build --no-link .#checks.x86_64-linux.cve-tools
# Run the same fixtures on any host with Nix, including macOS.
nix shell --inputs-from . nixpkgs#{bash,coreutils,gawk,gnugrep,jq,python3} -c python3 test/ci/cve-tests.py test/ci

# Evaluate the flake and run checks for the current supported system.
nix flake check --all-systems
```

[configuration.nix](./configuration.nix) uses `lib.debug.runTests` to check
defaults, module integration, and rejected configurations. Failures report the
case name, expected value, and actual value. These fixtures are independent of
VM scenarios. The REST allowlist cases also run here, rather than waiting for
a VM to report evaluation failures.

[runner-tests.py](./runner-tests.py) loads the assembled suite and checks test
selection, ordering, registration errors, and interactive dispatch using a
machine stub. Both checks are exposed for `x86_64-linux` and `aarch64-linux`,
and the existing CI `check_flake` job runs them through `nix flake check`.
[ci/cve-tests.py](./ci/cve-tests.py), exposed as the `cve-tools` check, exercises
scan failures, whitelist filtering, and issue reporting with local command stubs.
The same CI job evaluates [ci/scan-node.nix](./ci/scan-node.nix) without building
the node or fetching NVD feeds. The scheduled CVE workflow builds and scans it.
The `deployment_examples` job runs [ci/deployment-examples.sh](./ci/deployment-examples.sh)
(also `./run-tests.sh deploymentExamples`). It builds every deployment example in
[../examples](../examples) with its own tool against the checkout, one step per example:
`examples/flakes` with `nixos-rebuild build --flake` and `examples/colmena` with
`colmena build`. The examples pin a release and its `configVersion`; the script locks
them to the checkout and sets the checkout's latest `configVersion`.
The `shellcheck` and `nixos_search` jobs run independently, so shell linting and
fast checks can finish while package and option extraction is still running.
The required `ci_gate` waits for all jobs and requires them to succeed; only
`test_scenario` may be skipped when the VM tests are already cached, and
`cache_flake_info` is skipped on pull requests.
Permissions, secrets, namespace isolation, backups, and service restarts still
need the VM tests.

### Tutorial
#### Running tests
```bash
# Run the basic set of tests. These tests are also run on the GitHub CI server.
./run-tests.sh

# Run the test for scenario `regtest`.
# The test is run via the Nix build system. Successful runs are cached.
./run-tests.sh -s regtest build
./run-tests.sh -s regtest # Shorthand, equivalent

# To test a single service, use its name as a scenario.
./run-tests.sh -s clightning

# When no scenario is specified, scenario `default` is used.
./run-tests.sh build
```
#### Debugging
```bash
# Start a shell inside a test VM. No tests are executed.
./run-tests.sh -s bitcoind vm
systemctl status bitcoind

# Run a Python NixOS test shell inside a VM.
# See https://nixos.org/manual/nixos/stable/#ssec-machine-objects for available commands.
./run-tests.sh debug
print(succeed("systemctl status bitcoind"))
run_test("bitcoind")

# Start a shell in a container node. Requires systemd and root privileges.
./run-tests.sh container

# In the container shell: Run command in container (with prefix `c`)
c systemctl status bitcoind

# Explore a single feature
./run-tests.sh -s electrs container

# Run a command in a container.
# The container is deleted afterwards.
./run-tests.sh -s clightning container --run c lightning-cli getinfo

# Define a custom scenario
./run-tests.sh --scenario '{
  services.clightning.enable = true;
  nix-bitcoin.nodeinfo.enable = true;
}' container --run c nodeinfo
```

# Running tests with Flakes

Tests can also be accessed via the bitcoinix flake:

```bash
# Build test
nix build --no-link ..#tests.default

# Run a node in a VM. No tests are executed.
nix run ..#tests.default.vm

# Run a Python test shell inside a VM node
nix run ..#tests.default.run -- --debug

# Run a node in a container. Requires extra-container, systemd and root privileges
nix run ..#tests.default.container
nix run ..#tests.default.containerLegacy # For NixOS with `system.stateVersion` <22.05

# Run a command in a container
nix run ..#tests.default.container -- --run c nodeinfo
nix run ..#tests.default.containerLegacy -- --run c nodeinfo # For NixOS with `system.stateVersion` <22.05
```

## nixos-search CI check

The `nixos_search` job runs [`nixos-search/ci-test.sh`](./nixos-search/ci-test.sh)
to check that `flake-info` can extract the repository's packages and NixOS options.
Both the job and the standalone script configure two binary caches:

- `bitcoinix.cachix.org` provides our `flake-info` build with the offline patches.
- `nixos-search.cachix.org` provides upstream dependencies, including its patched
  Nix, so a missing bitcoinix build does not require compiling Nix and running its
  test suites when those dependencies are cached upstream.

The separate `cache_flake_info` job builds `flake-info` and uploads its closure to
the bitcoinix cache. It runs only on pushes to `master` and is the only job of the
two that has the signing key. It never runs `flake-info`: the binary runs outside
the Nix build sandbox in `nixos_search`, and a secret that any step of a job uses
stays in the runner process for the whole job, so the two must not share a job.
Pull requests read the caches without uploading.

After changing `nixos-search/flake.lock` or the offline patches, the first run may
need to build `flake-info`. A successful master upload lets subsequent runs fetch
that build. To verify the cache after an upload, rerun `nixos_search` on a fresh CI
runner and check that it downloads `flake-info` instead of compiling it.
